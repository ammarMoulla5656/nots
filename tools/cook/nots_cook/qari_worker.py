"""Reads page images with Qari-OCR, an Arabic vision model that also reads
diacritics.

The merged float16 model is cached once as (.safetensors) files on the fast
C: SSD (AppData/Local/nots_cook_ssd/qari_merged_fp16).

A card with room for the whole float16 model (about 5 GB free, RTX 3050 6 GB
and up) holds it as is and reads several passages at once: on an old CPU the
GPU waits for Python between tokens, and a batch of passages costs little more
per token than one. Measured on an RTX 3050 with a Xeon E5-2690 v2, 51 real
passages: 4-bit 354 s, float16 259 s, and 4-bit changed ~30% of the reading.

Smaller cards with enough free VRAM hold the whole model on the GPU, the
language layers in 4-bit and the vision tower in float16: quantizing the vision
tower blinds the model, which then writes fluent English that has nothing to do
with the page.

Otherwise a 3-Tier Hierarchical Memory Pipeline is used:
    Tier 3 (C: SSD)  -->  Tier 2 (System RAM)  -->  Tier 1 (GPU VRAM cuda:0)

1. Free GPU VRAM and free System RAM are measured dynamically.
2. GPU VRAM is filled to maximum safe capacity.
3. Overflow layers reside in System RAM and stream into GPU VRAM
   (main_device=0) on every forward pass so 100% of layers execute on the GPU.
4. When System RAM fills up, overflow layers automatically spill to the
   C: SSD offload buffer (offload_dir), streaming SSD -> RAM -> GPU VRAM.
"""

import argparse
import gc
import json
import os
import shutil
import sys
import time
from pathlib import Path

os.environ.setdefault('HF_HUB_OFFLINE', '1')
os.environ.setdefault('TRANSFORMERS_OFFLINE', '1')

import psutil
import torch
import transformers
from peft import PeftModel
from PIL import Image
from qwen_vl_utils import process_vision_info
from transformers import AutoProcessor, Qwen2VLForConditionalGeneration

BASE = 'Qwen/Qwen2-VL-2B-Instruct'
ADAPTER = 'NAMAA-Space/Qari-OCR-0.2.2.1-VL-2B-Instruct'
PROMPT = ('Below is the image of one page of a document, as well as some raw textual content '
          'that was previously extracted for it. Just return the plain text representation '
          'of this document as if you were reading it naturally. Do not hallucinate.')

# What the 4-bit model needs in VRAM: 2.4 GB of weights and the rest to read with.
FREE_VRAM_FOR_4BIT_MB = 2900
# What the float16 model needs: 4.4 GB of weights and the rest to read a batch with.
FREE_VRAM_FOR_FP16_MB = 5000


def _ssd_root() -> Path:
    """Returns a fast directory physically located on the C: SSD for
    memory-mapped model caching and RAM->SSD overflow."""
    local_app = os.environ.get('LOCALAPPDATA') or str(Path.home() / 'AppData/Local')
    root = Path(local_app) / 'nots_cook_ssd'
    root.mkdir(parents=True, exist_ok=True)
    return root


def _merged(base):
    """[base] with the Qari adapter merged in. With transformers 5 the adapter
    loads without a word and does nothing, which leaves plain Qwen2-VL."""
    peft = PeftModel.from_pretrained(base, ADAPTER)
    if not any('lora_B' in n and p.abs().sum() > 0 for n, p in peft.named_parameters()):
        sys.exit(f'Error: the Qari adapter did not load with transformers {transformers.__version__}; '
                 'use transformers==4.51.3 (qari_requirements.txt)')
    return peft.merge_and_unload()


def _ensure_merged_on_ssd(dtype) -> str:
    """Caches the merged Qwen2-VL + Qari adapter in float16 (.safetensors) on
    the C: SSD once so subsequent runs memory-map it directly from the SSD
    into RAM -> GPU VRAM in a few seconds."""
    ssd = _ssd_root()
    merged_dir = ssd / 'qari_merged_fp16'
    if (merged_dir / 'model.safetensors.index.json').exists() or (merged_dir / 'model.safetensors').exists():
        return str(merged_dir)

    try:
        free_gb = shutil.disk_usage(str(ssd)).free / (1024 ** 3)
    except Exception:
        free_gb = 0
    if free_gb < 6.0:
        return ''

    print('preparing merged float16 model on C: SSD (one-time setup for fast mmap)...',
          file=sys.stderr, flush=True)
    t0 = time.time()
    tmp_dir = ssd / 'qari_merged_fp16_tmp'
    shutil.rmtree(tmp_dir, ignore_errors=True)
    base = Qwen2VLForConditionalGeneration.from_pretrained(
        BASE, torch_dtype=torch.float16, low_cpu_mem_usage=True, device_map=None
    )
    model = _merged(base)
    model.eval()
    model.save_pretrained(str(tmp_dir), safe_serialization=True, max_shard_size='2GB')
    AutoProcessor.from_pretrained(BASE).save_pretrained(str(tmp_dir))
    del model, base
    if torch.cuda.is_available():
        torch.cuda.empty_cache()
    shutil.rmtree(merged_dir, ignore_errors=True)
    tmp_dir.rename(merged_dir)
    print(f'cached merged model on C: SSD in {time.time() - t0:.1f}s -> {merged_dir}',
          file=sys.stderr, flush=True)
    return str(merged_dir)


def _configure_device(requested_max_pixels: int):
    cuda = torch.cuda.is_available()
    cpu_threads = int(os.environ.get('NOTS_QARI_THREADS') or 0) or (os.cpu_count() or 4)
    torch.set_num_threads(cpu_threads if not cuda else min(cpu_threads, 4))
    if not cuda:
        return False, torch.float32, min(requested_max_pixels, 700_000), 0, 'cpu'

    props = torch.cuda.get_device_properties(0)
    vram_mb = props.total_memory // (1024 * 1024)
    gpu_name = props.name
    torch.backends.cudnn.benchmark = True
    if props.major >= 8:
        torch.backends.cuda.matmul.allow_tf32 = True
        torch.backends.cudnn.allow_tf32 = True

    bf16_ok = bool(getattr(torch.cuda, 'is_bf16_supported', lambda: False)()) and props.major >= 8
    dtype = torch.bfloat16 if bf16_ok else torch.float16

    if vram_mb <= 4600:
        max_pixels = min(requested_max_pixels, 320_000)
    elif vram_mb <= 6600:
        max_pixels = min(requested_max_pixels, 750_000)
    else:
        max_pixels = requested_max_pixels

    desc = f'cuda ({gpu_name}, {vram_mb} MiB, {str(dtype).split(".")[-1]})'
    return True, dtype, max_pixels, vram_mb, desc


def _load_4bit_on_gpu(merged_path: str, dtype):
    """The language layers in 4-bit (NF4) and the vision tower in float16,
    all inside VRAM (~2.4 GB): no layer lives in RAM, so nothing crosses the
    PCIe bus per token and the GPU computes all the time instead of waiting.
    Returns None when bitsandbytes is missing or other programs hold the VRAM."""
    try:
        import importlib.util
        if not importlib.util.find_spec('bitsandbytes'):
            return None
        free_mb = torch.cuda.mem_get_info(0)[0] // (1024 * 1024)
        if free_mb < FREE_VRAM_FOR_4BIT_MB:
            print(f'warning: only {free_mb} MiB of VRAM free; using RAM streaming',
                  file=sys.stderr, flush=True)
            return None
        from transformers import BitsAndBytesConfig
        # Pascal and older run half precision at 1/64 of float32 speed: the
        # 4-bit kernel in float32 reads the same text more than twice as fast.
        compute = dtype if torch.cuda.get_device_properties(0).major >= 7 else torch.float32
        q = BitsAndBytesConfig(load_in_4bit=True, bnb_4bit_quant_type='nf4',
                               bnb_4bit_compute_dtype=compute, bnb_4bit_use_double_quant=True,
                               llm_int8_skip_modules=['lm_head', 'visual'])
        return Qwen2VLForConditionalGeneration.from_pretrained(
            merged_path, quantization_config=q, torch_dtype=dtype,
            low_cpu_mem_usage=True, device_map={'': 0})
    except Exception as e:
        print(f'warning: 4-bit load failed ({e}); using RAM streaming', file=sys.stderr, flush=True)
    gc.collect()
    torch.cuda.empty_cache()
    return None


def _load_model_3tier(cuda: bool, dtype, vram_mb: int) -> tuple[Qwen2VLForConditionalGeneration, str]:
    """Loads the model across the 3-tier hierarchy:
        C: SSD (mmap / offload_dir) -> System RAM -> GPU VRAM (cuda:0)
    with main_device=0 so all layers execute on the GPU."""
    ssd_dir = _ssd_root()
    offload_dir = ssd_dir / 'offload_swap'
    offload_dir.mkdir(parents=True, exist_ok=True)

    merged_path = _ensure_merged_on_ssd(dtype) if cuda else ''

    # Small cards: whole model in VRAM at 4-bit beats streaming fp16 layers from RAM.
    # A card that holds float16 reads faster and better with it (NOTS_QARI_4BIT=1 forces 4-bit).
    free_mb = torch.cuda.mem_get_info(0)[0] // (1024 * 1024) if cuda else 0
    force_4bit = os.environ.get('NOTS_QARI_4BIT')
    want_4bit = force_4bit == '1' or (force_4bit != '0' and vram_mb < 7000
                                       and free_mb < FREE_VRAM_FOR_FP16_MB)
    if cuda and merged_path and want_4bit:
        m4 = _load_4bit_on_gpu(merged_path, dtype)
        if m4 is not None:
            m4.eval()
            if hasattr(m4, 'generation_config'):
                m4.generation_config.temperature = None
                m4.generation_config.top_p = None
                m4.generation_config.top_k = None
            print('Memory Map: 100% of layers in GPU VRAM (language 4-bit NF4, vision float16, '
                  'no RAM streaming)',
                  file=sys.stderr, flush=True)
            return m4, merged_path

    if merged_path:
        model = Qwen2VLForConditionalGeneration.from_pretrained(
            merged_path, torch_dtype=dtype, low_cpu_mem_usage=True, device_map=None
        )
        proc_source = merged_path
    else:
        base = Qwen2VLForConditionalGeneration.from_pretrained(
            BASE, torch_dtype=dtype, low_cpu_mem_usage=True, device_map=None
        )
        model = _merged(base)
        proc_source = BASE

    model.eval()
    if hasattr(model, 'generation_config'):
        model.generation_config.temperature = None
        model.generation_config.top_p = None
        model.generation_config.top_k = None
    if not cuda:
        return model, proc_source

    torch.cuda.empty_cache()
    free_vram_b, _ = torch.cuda.mem_get_info(0)
    free_vram_mb = int(free_vram_b // (1024 * 1024))

    vm = psutil.virtual_memory()
    avail_ram_mb = int(vm.available // (1024 * 1024))

    # If the GPU has >= 4900 MiB free VRAM, fit 100% directly in VRAM
    if free_vram_mb >= 4900 and vram_mb >= 6000:
        return model.to('cuda:0'), proc_source

    # 3-Tier Memory Budget:
    # On Windows 10/11 WDDM, a 4096 MiB GPU has ~2840 MiB usable by PyTorch
    # (the rest is used by Windows DWM/desktop), and streaming + vision activations
    # need ~750 MiB of free dynamic VRAM headroom during model.generate().
    if vram_mb <= 4600:
        vram_budget_mb = min(2100, max(1200, free_vram_mb - 1250))
    else:
        vram_budget_mb = max(1600, free_vram_mb - 1100)
    # Tier 2 (System RAM): Use up to 80% of available RAM; anything beyond spills to Tier 3 (C: SSD offload_dir)
    ram_budget_mb = max(600, int(avail_ram_mb * 0.80))

    from accelerate import dispatch_model, infer_auto_device_map
    no_split = getattr(model, '_no_split_modules', ['Qwen2VLDecoderLayer', 'Qwen2VLVisionBlock'])
    device_map = infer_auto_device_map(
        model,
        max_memory={0: f'{vram_budget_mb}MiB', 'cpu': f'{ram_budget_mb}MiB'},
        no_split_module_classes=no_split,
        dtype=dtype,
    )
    # main_device=0 ensures layers stored in System RAM ('cpu') or C: SSD ('disk')
    # stream into GPU VRAM (cuda:0) layer-by-layer and execute on the GPU!
    model = dispatch_model(
        model,
        device_map=device_map,
        main_device=0,
        offload_dir=str(offload_dir),
        offload_buffers=True,
    )
    tiers = collections.Counter(str(v) for v in device_map.values())
    print(f'3-Tier Memory Map: GPU(cuda:0)={vram_budget_mb}MiB, RAM={ram_budget_mb}MiB, '
          f'SSD={offload_dir} | modules={dict(tiers)}', file=sys.stderr, flush=True)
    return model, proc_source


import collections  # noqa: E402


def _keep_last_logits(model) -> None:
    """generate() only looks at the last position, but the head would turn the
    whole prompt into logits: over 100 MiB per passage of VRAM for nothing."""
    model.lm_head.register_forward_pre_hook(lambda _, args: (args[0][:, -1:, :],))


def _infer_many(model, processor, imgs: list[Image.Image], max_tokens: int) -> list[tuple[str, int]]:
    """Reads [imgs] in one batch (left padding, so every passage ends where
    the model continues). Returns the text and new token count of each."""
    prompts, images = [], []
    for img in imgs:
        messages = [{'role': 'user', 'content': [
            {'type': 'image', 'image': img},
            {'type': 'text', 'text': PROMPT},
        ]}]
        prompts.append(processor.apply_chat_template(messages, tokenize=False, add_generation_prompt=True))
        images.extend(process_vision_info(messages)[0])
    dev = torch.device('cuda:0') if torch.cuda.is_available() else torch.device('cpu')
    inputs = processor(text=prompts, images=images, padding=True,
                       return_tensors='pt').to(dev, non_blocking=True)
    in_len = int(inputs.input_ids.shape[1])
    with torch.inference_mode():
        ids = model.generate(
            **inputs,
            max_new_tokens=max_tokens,
            do_sample=False,
            repetition_penalty=1.15,
            pad_token_id=processor.tokenizer.pad_token_id,
        )
    new = ids[:, in_len:]
    texts = processor.batch_decode(new, skip_special_tokens=True)
    pad = processor.tokenizer.pad_token_id
    counts = [int((row != pad).sum()) for row in new]
    del inputs, ids, new
    return list(zip(texts, counts))


def _infer_one(model, processor, img: Image.Image, max_tokens: int) -> tuple[str, int]:
    return _infer_many(model, processor, [img], max_tokens)[0]


def _read(model, processor, path: str, tok_limit: int, cuda: bool) -> tuple[str, int]:
    """The passage in the image at [path]. One that runs out of memory is read
    at half size, and one that cannot be read is skipped: a single passage
    must not end the run. The retry comes after the except block, which would
    hold on to the failed tensors and keep their VRAM taken."""
    img = None
    try:
        img = Image.open(path).convert('RGB')
        return _infer_one(model, processor, img, tok_limit)
    except Exception as e:
        error = str(e)
    if img is not None and cuda and 'out of memory' in error.lower():
        gc.collect()
        torch.cuda.empty_cache()
        w, h = img.size
        small = img.resize((max(64, w // 2), max(64, h // 2)), Image.Resampling.LANCZOS)
        try:
            return _infer_one(model, processor, small, min(tok_limit, 300))
        except Exception as e:
            error = str(e)
        gc.collect()
        torch.cuda.empty_cache()
    print(f'warning: skipped passage {path} ({error})', file=sys.stderr, flush=True)
    return '', 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('list', nargs='?')
    ap.add_argument('out', nargs='?')
    ap.add_argument('--tokens', type=int, default=700)
    ap.add_argument('--max-pixels', type=int, default=1400000)
    ap.add_argument('--serve', help='a folder to take lists of passages from, one after another')
    ap.add_argument('--parent', type=int, default=0, help='stop serving when this process is gone')
    args = ap.parse_args()
    if not args.serve and not (args.list and args.out):
        ap.error('a list and an output file, or --serve')

    cuda, dtype, max_pixels, vram_mb, dev_desc = _configure_device(args.max_pixels)
    t0 = time.time()
    model, proc_source = _load_model_3tier(cuda, dtype, vram_mb)
    _keep_last_logits(model)
    processor = AutoProcessor.from_pretrained(proc_source, max_pixels=max_pixels)
    alloc_mb = (torch.cuda.memory_allocated(0) // (1024 * 1024)) if cuda else 0
    print(f'loaded on {dev_desc} in {time.time() - t0:.1f}s (VRAM allocated={alloc_mb} MiB, max_pixels={max_pixels}, '
          f'transformers {transformers.__version__})', file=sys.stderr, flush=True)

    batch = _batch_size(model, cuda)
    processor.tokenizer.padding_side = 'left'
    if batch > 1:
        print(f'reading {batch} passages at a time', file=sys.stderr, flush=True)
    if args.serve:
        _serve(Path(args.serve), args.parent, model, processor, cuda, batch, args.tokens)
    else:
        _run(_jobs(args.list, args.tokens), args.out, model, processor, cuda, batch)


def _jobs(path, tokens: int) -> list[tuple[str, int]]:
    jobs = []
    with open(path, encoding='utf-8') as f:
        for raw_line in f:
            raw_line = raw_line.strip()
            if not raw_line:
                continue
            parts = raw_line.split('\t')
            tok_limit = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else tokens
            jobs.append((parts[0], tok_limit))
    return jobs


def _serve(folder: Path, parent: int, model, processor, cuda: bool, batch: int, tokens: int):
    """Keeps the model loaded and reads each list put in [folder] as
    job*.txt into job*.jsonl, then renames the list job*.done. Loading takes
    from 15 s to over a minute while the CPU is busy, and a book asks for
    passages more than once: started early, the model is ready when the
    first passages are. Stops on a file named 'stop' or when [parent] ends."""
    while True:
        if (folder / 'stop').exists() or (parent and not psutil.pid_exists(parent)):
            return
        lists = sorted(folder.glob('job*.txt'))
        if not lists:
            time.sleep(0.2)
            continue
        job = lists[0]
        _run(_jobs(job, tokens), job.with_suffix('.jsonl'), model, processor, cuda, batch)
        job.rename(job.with_suffix('.done'))


def _run(jobs, out_path, model, processor, cuda: bool, batch: int):
    if batch > 1:
        # Passages of like length together: a batch runs as long as its longest.
        jobs = sorted(jobs, key=lambda j: j[1])
    with open(out_path, 'a', encoding='utf-8') as out:
        def write(path, text, seconds, tokens):
            out.write(json.dumps({
                'name': os.path.splitext(os.path.basename(path))[0],
                'text': text,
                'seconds': round(seconds, 1),
                'tokens': tokens,
            }, ensure_ascii=False) + '\n')
            out.flush()

        for i in range(0, len(jobs), batch):
            group = jobs[i:i + batch]
            t = time.time()
            results = _read_batch(model, processor, group) if len(group) > 1 else None
            if results is None:  # one passage, or the batch failed: one at a time
                for path, tok_limit in group:
                    t1 = time.time()
                    text, gen_tokens = _read(model, processor, path, tok_limit, cuda)
                    write(path, text, time.time() - t1, gen_tokens)
                continue
            each = (time.time() - t) / len(group)
            for (path, _), (text, gen_tokens) in zip(group, results):
                write(path, text, each, gen_tokens)


def _batch_size(model, cuda: bool) -> int:
    """How many passages to read at once: several when the whole float16
    model sits in VRAM, else one (4-bit and streamed layers were measured
    slower in batches on a GTX 1050 Ti). NOTS_QARI_BATCH overrides."""
    env = os.environ.get('NOTS_QARI_BATCH')
    if env and env.isdigit() and int(env) > 0:
        return int(env)
    if not cuda or getattr(model, 'is_loaded_in_4bit', False) or getattr(model, 'hf_device_map', None):
        return 1
    return 4


def _read_batch(model, processor, group) -> list[tuple[str, int]] | None:
    """[group] read together, or None when that fails (out of memory most
    often), so the caller reads them one at a time."""
    try:
        imgs = [Image.open(p).convert('RGB') for p, _ in group]
        return _infer_many(model, processor, imgs, max(t for _, t in group))
    except Exception as e:
        print(f'warning: batch of {len(group)} failed ({str(e)[:120]}); one at a time',
              file=sys.stderr, flush=True)
    gc.collect()
    if torch.cuda.is_available():
        torch.cuda.empty_cache()
    return None


if __name__ == '__main__':
    main()
