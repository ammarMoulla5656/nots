<?php
// A book on its way from the Xeon to the browser. The server only relays it:
// the file is deleted as soon as it has been sent whole, and any file left
// behind (a download given up) is deleted after an hour.
require __DIR__ . '/_auth.php';
nots_require_login();
header('Cache-Control: no-store');
$dir = __DIR__ . '/_dl';
foreach (glob($dir . '/*') ?: [] as $p) {
    if (is_file($p) && basename($p) !== '.htaccess' && time() - filemtime($p) > 3600) {
        @unlink($p);
    }
}
$serial = preg_replace('/\D/', '', (string)($_GET['serial'] ?? ''));
if (strlen($serial) !== 4) {
    http_response_code(400);
    exit('bad serial');
}
$pdf = "$dir/$serial.pdf";
$err = "$dir/$serial.err";
$req = "$dir/$serial.req";
$name = "$dir/$serial.name";

if (isset($_GET['check'])) {
    header('Content-Type: application/json; charset=utf-8');
    $out = ['state' => 'none'];
    if (is_file($pdf)) {
        $out = ['state' => 'ready', 'size' => filesize($pdf)];
    } elseif (is_file($err)) {
        $out = ['state' => 'error', 'message' => trim((string)file_get_contents($err))];
    } elseif (is_file($req)) {
        $age = time() - filemtime($req);
        $agent = @filemtime(__DIR__ . '/_data/agent.txt') ?: 0;
        if ($age > 600) {
            $out = ['state' => 'error', 'message' => 'لم يستجب الخادم في 10 دقائق'];
        } elseif (time() - $agent > 60) {
            $out = ['state' => 'pending', 'note' => 'الخادم لا يردّ الآن (مطفأ أو بلا إنترنت)'];
        } else {
            $out = ['state' => 'pending'];
        }
    }
    echo json_encode($out, JSON_UNESCAPED_UNICODE);
    exit;
}

if (!is_file($pdf)) {
    http_response_code(404);
    header('Content-Type: text/plain; charset=utf-8');
    exit('الكتاب ليس هنا (نُزّل من قبل، أو لم يصل بعد)');
}
$fileName = is_file($name) ? trim((string)file_get_contents($name)) : "$serial.pdf";
$ascii = preg_replace('/[^A-Za-z0-9._-]+/', '_', $fileName);
if ($ascii === '' || $ascii === '_.pdf' || trim($ascii, '_.') === 'pdf') {
    $ascii = "$serial.pdf";
}
while (ob_get_level()) {
    ob_end_clean();
}
ignore_user_abort(true);
set_time_limit(0);
$size = filesize($pdf);
header('Content-Type: application/pdf');
header('Content-Length: ' . $size);
header('Content-Disposition: attachment; filename="' . $ascii . '"; filename*=UTF-8\'\'' . rawurlencode($fileName));
$sent = readfile($pdf);
if ($sent === $size && !connection_aborted()) {
    foreach ([$pdf, $name, $req, $err] as $p) {
        @unlink($p);
    }
}
