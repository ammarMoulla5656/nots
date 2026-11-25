<?php
// The tunnel: a volume that lives on the home server, handed to the app.
//
// The books are not kept here. The app asks for t/get.php?s=0001; this page
// asks the home server (the Xeon) for it through the monitor's command file,
// and the Xeon sends it into ../monitor/_dl. The volume reaches the app
// while it is still arriving here, so the app waits only for the first bytes.
// What arrived stays a short while for the next reader (another phone, a
// resumed download), and is then deleted by the Xeon and by this page.
//
// The app checks the size and sha256 from the catalogue, so a wrong or
// incomplete file is never imported.
declare(strict_types=1);

const WAIT_START = 25;   // seconds to wait for the first bytes (the app waits 30)
const STALL = 90;        // seconds without a new byte before giving up
const KEEP = 1800;       // seconds an unused volume stays here
const AGENT_LATE = 60;   // the Xeon asks for commands every 4 s

$mon = dirname(__DIR__) . '/monitor';
$dl = "$mon/_dl";
$data = "$mon/_data";
$list = require __DIR__ . '/_list.php';   // serial => size, only the catalogue's volumes

function fail(int $code, string $msg): void {
    http_response_code($code);
    header('Content-Type: text/plain; charset=utf-8');
    header('Cache-Control: no-store');
    if ($code === 503) {
        header('Retry-After: 60');
    }
    exit($msg);
}

$serial = (string)($_GET['s'] ?? '');
if (!preg_match('/^\d{4}$/', $serial) || !isset($list[$serial])) {
    fail(404, 'no such book');
}
$total = (int)$list[$serial];
$pdf = "$dl/$serial.pdf";
$part = "$pdf.part";
$err = "$dl/$serial.err";

// Old volumes nobody read for a while.
foreach (glob("$dl/*") ?: [] as $p) {
    if (is_file($p) && time() - filemtime($p) > KEEP + 600) {
        @unlink($p);
    }
}

// The requested range: the app resumes with "bytes=N-".
$start = 0;
$end = $total - 1;
$range = (string)($_SERVER['HTTP_RANGE'] ?? '');
if ($range !== '') {
    if (!preg_match('/^bytes=(\d*)-(\d*)$/', trim($range), $m) || ($m[1] === '' && $m[2] === '')) {
        fail(416, 'bad range');
    }
    if ($m[1] === '') {                 // the last N bytes
        $start = max(0, $total - (int)$m[2]);
    } else {
        $start = (int)$m[1];
        if ($m[2] !== '') {
            $end = min($end, (int)$m[2]);
        }
    }
    if ($start > $end || $start >= $total) {
        header("Content-Range: bytes */$total");
        fail(416, 'range not satisfiable');
    }
}

/** The volume here, whole or still arriving, opened; null when absent. */
function open_volume(string $pdf, string $part, int $total) {
    clearstatcache();
    if (is_file($pdf) && filesize($pdf) === $total) {
        return @fopen($pdf, 'rb') ?: null;
    }
    if (is_file($part)) {
        return @fopen($part, 'rb') ?: null;
    }
    return null;
}

$fh = open_volume($pdf, $part, $total);
if ($fh === null) {
    $agent = @filemtime("$data/agent.txt") ?: 0;
    if (time() - $agent > AGENT_LATE) {
        fail(503, 'الخادم المنزلي لا يردّ الآن (مطفأ أو بلا إنترنت). أعد المحاولة لاحقاً.');
    }
    @unlink($err);
    // One request is enough: the Xeon ignores a volume it is already sending.
    file_put_contents("$data/cmd.txt", "fetch:$serial\n", FILE_APPEND | LOCK_EX);
    $until = microtime(true) + WAIT_START;
    while ($fh === null && microtime(true) < $until) {
        usleep(300000);
        if (is_file($err)) {
            $msg = trim((string)@file_get_contents($err));
            @unlink($err);
            fail(502, 'تعذّر على الخادم المنزلي إرسال الكتاب: ' . $msg);
        }
        $fh = open_volume($pdf, $part, $total);
    }
    if ($fh === null) {
        fail(503, 'الخادم المنزلي بطيء الآن. أعد المحاولة.');
    }
}

// Straight to the app, no buffering or compression on the way.
@ini_set('zlib.output_compression', '0');
@ini_set('output_buffering', '0');
if (function_exists('apache_setenv')) {
    @apache_setenv('no-gzip', '1');
}
while (ob_get_level()) {
    ob_end_clean();
}
set_time_limit(0);
ignore_user_abort(false);

$length = $end - $start + 1;
http_response_code($start > 0 || $end < $total - 1 ? 206 : 200);
if ($start > 0 || $end < $total - 1) {
    header("Content-Range: bytes $start-$end/$total");
}
header('Content-Type: application/pdf');
header('Content-Length: ' . $length);
header('Accept-Ranges: bytes');
header('Cache-Control: no-store');
header('X-Accel-Buffering: no');
header('Content-Encoding: identity');
flush();

$pos = $start;
$last = microtime(true);
$touched = 0;
fseek($fh, $pos);
while ($pos <= $end) {
    if (connection_aborted()) {
        break;
    }
    $want = min(256 * 1024, $end - $pos + 1);
    $chunk = fread($fh, $want);
    if ($chunk !== false && $chunk !== '') {
        echo $chunk;
        flush();
        $pos += strlen($chunk);
        $last = microtime(true);
        continue;
    }
    // Not arrived yet: wait for the Xeon.
    if (microtime(true) - $last > STALL || is_file($err)) {
        break;   // the app sees a short file and resumes later
    }
    if (time() - $touched > 20) {   // keep it while it is being read
        $touched = time();
        @touch(is_file($pdf) ? $pdf : $part);
    }
    usleep(200000);
    fseek($fh, $pos);   // clears the end-of-file mark
}
fclose($fh);
@touch($pdf);
