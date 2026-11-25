"""Sets up Qari-OCR on the NVIDIA card of this machine: its own Python
environment, PyTorch with CUDA and the model. The CUDA libraries come inside
the PyTorch package, so nothing else is installed but a recent card driver.

Run by the CUDA button of the interface, or by hand:

    python setup_gpu.py [--cuda cu128|cu118] [--venv FOLDER] [--no-model]

Uses the standard library only: it runs before anything is installed.
"""

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REQUIREMENTS = HERE.parent / 'qari_requirements.txt'
TORCH, TORCHVISION = '2.7.1', '0.22.1'
MODELS = ('Qwen/Qwen2-VL-2B-Instruct', 'NAMAA-Space/Qari-OCR-0.2.2.1-VL-2B-Instruct')
PYTHONS = ('3.12', '3.13', '3.11', '3.10')  # PyTorch 2.7 has no build for 3.14
MIN_DRIVER_CU128 = 570  # RTX 50 cards exist only from CUDA 12.8 on
FREE_GB_NEEDED = 20     # PyTorch 6, the model 4.5, its merged copy 4, and room to work
NO_WINDOW = getattr(subprocess, 'CREATE_NO_WINDOW', 0)


def default_venv() -> Path:
    local = os.environ.get('LOCALAPPDATA') or str(Path.home() / 'AppData/Local')
    return Path(local) / 'nots_cook_ssd' / 'qari_venv'


def say(text: str) -> None:
    print(text, flush=True)


def fail(text: str) -> None:
    say(f'✗ {text}')
    sys.exit(1)


def run(cmd: list[str], env: dict | None = None) -> None:
    say('$ ' + ' '.join(cmd))
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                         encoding='utf-8', errors='replace', creationflags=NO_WINDOW, env=env)
    for line in p.stdout:
        say(line.rstrip())
    if p.wait() != 0:
        fail(f'فشلت الخطوة (رمز الخروج {p.returncode})')


def card() -> tuple[str, int]:
    """The name of the NVIDIA card and the major version of its driver."""
    smi = shutil.which('nvidia-smi') or r'C:\Windows\System32\nvidia-smi.exe'
    try:
        r = subprocess.run([smi, '--query-gpu=name,driver_version', '--format=csv,noheader'],
                           capture_output=True, text=True, timeout=20, creationflags=NO_WINDOW)
        name, driver = r.stdout.splitlines()[0].rsplit(',', 1)
        return name.strip(), int(driver.strip().split('.')[0])
    except (OSError, ValueError, IndexError, subprocess.SubprocessError):
        fail('لم يُعثر على كرت NVIDIA أو تعريفه: ثبّت تعريف الكرت من nvidia.com ثم أعد المحاولة')


def cuda_for(name: str, driver: int) -> str:
    if driver >= MIN_DRIVER_CU128:
        return 'cu128'
    if 'RTX 50' in name:
        fail(f'تعريف {name} قديم (الإصدار {driver}). هذا الكرت يحتاج الإصدار {MIN_DRIVER_CU128} أو أحدث: '
             'حدّثه من nvidia.com ثم أعد المحاولة')
    return 'cu118'


def python_version(cmd: list[str]) -> str | None:
    try:
        r = subprocess.run(cmd + ['-c', 'import sys; print("%d.%d" % sys.version_info[:2])'],
                           capture_output=True, text=True, timeout=30, creationflags=NO_WINDOW)
        return r.stdout.strip() if r.returncode == 0 else None
    except (OSError, subprocess.SubprocessError):
        return None


def find_python() -> list[str] | None:
    """A Python that PyTorch has a build for."""
    for version in PYTHONS:
        if python_version(['py', f'-{version}']) == version:
            return ['py', f'-{version}']
        folder = Path.home() / f'AppData/Local/Programs/Python/Python{version.replace(".", "")}/python.exe'
        if folder.exists() and python_version([str(folder)]) == version:
            return [str(folder)]
    return [sys.executable] if python_version([sys.executable]) in PYTHONS else None


def get_python() -> list[str]:
    found = find_python()
    if found:
        return found
    say('لا يوجد Python مناسب (3.10 إلى 3.13): جارٍ تثبيت Python 3.12 ...')
    if shutil.which('winget'):
        run(['winget', 'install', '-e', '--id', 'Python.Python.3.12', '--silent',
             '--accept-package-agreements', '--accept-source-agreements'])
    found = find_python()
    if not found:
        fail('ثبّت Python 3.12 من python.org ثم أعد المحاولة')
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--cuda', choices=['cu128', 'cu118'], help='default: what the card and its driver need')
    ap.add_argument('--venv', type=Path, default=default_venv())
    ap.add_argument('--no-model', action='store_true', help='do not download the model')
    ap.add_argument('--no-check', action='store_true', help='do not try the card at the end')
    args = ap.parse_args()

    name, driver = card()
    cuda = args.cuda or cuda_for(name, driver)
    say(f'الكرت: {name} | التعريف: {driver} | PyTorch {TORCH} + {cuda}')

    args.venv.parent.mkdir(parents=True, exist_ok=True)
    free_gb = shutil.disk_usage(args.venv.parent).free / 1024 ** 3
    if free_gb < FREE_GB_NEEDED:
        fail(f'المساحة الحرة {free_gb:.0f} GB فقط، والمطلوب {FREE_GB_NEEDED} GB')

    python = args.venv / 'Scripts' / 'python.exe'
    if not python.exists():
        python = args.venv / 'bin' / 'python' if sys.platform != 'win32' else python
    if not python.exists():
        say('\n[1/4] إنشاء بيئة Python ...')
        run(get_python() + ['-m', 'venv', str(args.venv)])

    say('\n[2/4] تنزيل PyTorch مع CUDA (نحو 3 GB) ...')
    run([str(python), '-m', 'pip', 'install', '--disable-pip-version-check',
         f'torch=={TORCH}+{cuda}', f'torchvision=={TORCHVISION}+{cuda}',
         '--index-url', f'https://download.pytorch.org/whl/{cuda}'])

    say('\n[3/4] تثبيت مكتبات Qari ...')
    run([str(python), '-m', 'pip', 'install', '--disable-pip-version-check', '-r', str(REQUIREMENTS)])

    if not args.no_model:
        say('\n[4/4] تنزيل نموذج Qari (نحو 4.5 GB، ويكمل من حيث توقف إن انقطع) ...')
        env = {k: v for k, v in os.environ.items() if k not in ('HF_HUB_OFFLINE', 'TRANSFORMERS_OFFLINE')}
        code = ('from huggingface_hub import snapshot_download\n'
                f'for m in {MODELS!r}:\n'
                '    print(m, flush=True)\n'
                '    snapshot_download(m)\n')
        run([str(python), '-c', code], env)

    if not args.no_check:
        say('\nتجربة الكرت ...')
        run([str(python), '-c',
             'import torch\n'
             'assert torch.cuda.is_available(), "CUDA is not available"\n'
             'x = torch.ones(512, 512, device="cuda", dtype=torch.float16)\n'
             'print(torch.cuda.get_device_name(0), "capability", torch.cuda.get_device_capability(0), '
             '"sum", float((x @ x).sum()))'])
    say('\n✓ اكتمل التجهيز: كرت الشاشة جاهز لقراءة Qari')


if __name__ == '__main__':
    main()
