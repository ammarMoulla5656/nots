<?php
// The Xeon asks here, every few seconds, for what the page's buttons left
// (start, pause, "send me book 0021"). Only the Xeon knows the key.
require __DIR__ . '/_config.php';
header('Cache-Control: no-store');
header('Content-Type: text/plain; charset=utf-8');
$key = (string)($_POST['key'] ?? '');
if (!defined('NOTS_AGENT_KEY') || !hash_equals(NOTS_AGENT_KEY, $key)) {
    http_response_code(403);
    exit('no');
}
@touch(__DIR__ . '/_data/agent.txt');          // the page shows whether the Xeon is listening
$f = __DIR__ . '/_data/cmd.txt';
if (!is_file($f)) {
    exit('');
}
$h = fopen($f, 'c+');
flock($h, LOCK_EX);
$text = stream_get_contents($h);
ftruncate($h, 0);
flock($h, LOCK_UN);
fclose($h);
echo $text;
