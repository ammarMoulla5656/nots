<?php
// The status the Xeon sends every 30 s (_data/status.txt), the list of the
// finished books (_data/done.txt), and the commands of the page's buttons,
// left in _data/cmd.txt for the Xeon to pick up (poll.php).
require __DIR__ . '/_auth.php';
nots_require_login();
header('Cache-Control: no-store');
$dir = __DIR__ . '/_data';
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $cmd = (string)($_GET['cmd'] ?? '');
    header('Content-Type: text/plain; charset=utf-8');
    if ($cmd === 'fetch') {
        // "send me this book": it goes to _dl for the browser to take, once.
        $serial = preg_replace('/\D/', '', (string)($_GET['serial'] ?? ''));
        if (strlen($serial) !== 4) {
            http_response_code(400);
            exit('bad serial');
        }
        $dl = __DIR__ . '/_dl';
        $waiting = glob($dl . '/*.pdf') ?: [];
        if (count($waiting) >= 8 && !is_file("$dl/$serial.pdf")) {
            http_response_code(429);
            exit('كتب كثيرة بانتظار التنزيل: نزّلها أولًا');
        }
        if (is_file("$dl/$serial.pdf")) {
            exit('ready');
        }
        @unlink("$dl/$serial.err");
        touch("$dl/$serial.req");
        file_put_contents($dir . '/cmd.txt', "fetch:$serial\n", FILE_APPEND | LOCK_EX);
        exit('ok');
    }
    if (!in_array($cmd, ['start', 'pause', 'resume', 'retry_failed', 'retry_skipped', 'redo_bad'], true)) {
        http_response_code(400);
        exit('unknown command');
    }
    file_put_contents($dir . '/cmd.txt', $cmd . "\n", FILE_APPEND | LOCK_EX);
    exit('ok');
}
header('Content-Type: application/json; charset=utf-8');
if (isset($_GET['power'])) {
    $f = $dir . '/power.txt';
    echo is_file($f) ? '{"age":' . (time() - filemtime($f)) . ',' . substr(file_get_contents($f), 1) : '{}';
    exit;
}
if (isset($_GET['list'])) {
    $f = $dir . '/done.txt';
    echo is_file($f) ? file_get_contents($f) : '[]';
    exit;
}
$f = $dir . '/status.txt';
if (!is_file($f)) {
    echo json_encode(['state' => 'لم يصل شيء من الخادم بعد', 'now' => 0, 'total' => 0, 'done' => 0, 'failed' => 0,
                      'running' => [], 'recent' => [], 'events' => [], 'failed_list' => [], 'metrics' => new stdClass,
                      'history' => []], JSON_UNESCAPED_UNICODE);
    exit;
}
// How long ago the Xeon sent it, by this server's clock (the Xeon's may differ).
$body = file_get_contents($f);
echo '{"age":' . (time() - filemtime($f)) . ',' . substr($body, 1);
