<?php
require __DIR__ . '/_auth.php';
$error = '';
if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['email'], $_POST['password'])) {
    if (nots_try_login((string)$_POST['email'], (string)$_POST['password'])) {
        header('Location: index.php');
        exit;
    }
    $error = 'البريد أو كلمة المرور غير صحيحة';
}
header('Cache-Control: no-store');
header('X-Robots-Tag: noindex, nofollow');
if (nots_logged_in()) {
    $html = file_get_contents(__DIR__ . '/_app/dashboard.html');
    $api = "<script>window.NOTS_API = {status: 'data.php', cmd: a => 'data.php?cmd=' + a, exportUrl: 'export.php',"
         . " done: 'data.php?list=1', power: 'data.php?power=1', relay: true, fetch: s => 'data.php?cmd=fetch&serial=' + s,"
         . " check: s => 'dl.php?check=1&serial=' + s, file: s => 'dl.php?serial=' + s};</script>";
    $logout = '<a class="btn" href="logout.php">خروج</a>';
    $html = str_replace('<script>', $api . "\n<script>", $html);
    $html = preg_replace('~(id="bExport"[^>]*>[^<]*</a>)~u', '$1 ' . $logout, $html, 1);
    echo $html;
    exit;
}
?><!doctype html>
<html lang="ar" dir="rtl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow"><title>دخول المراقبة</title>
<style>
:root{--bg:#f4f6f9;--card:#fff;--ink:#1d2733;--mute:#6b7785;--line:#e3e8ee;--acc:#1f6feb;--bad:#cf222e}
@media (prefers-color-scheme:dark){:root{--bg:#0f141a;--card:#171e26;--ink:#e6edf3;--mute:#8b98a5;--line:#26313d;--acc:#4493f8;--bad:#f85149}}
body{margin:0;min-height:100vh;display:grid;place-items:center;background:var(--bg);color:var(--ink);font:15px/1.5 "Segoe UI",Tahoma,sans-serif;padding:16px}
form{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:24px;width:100%;max-width:360px}
h1{font-size:18px;margin:0 0 16px}label{display:block;color:var(--mute);margin:10px 0 4px}
input{width:100%;box-sizing:border-box;padding:10px;border:1px solid var(--line);border-radius:8px;background:var(--bg);color:var(--ink);font:inherit}
button{margin-top:16px;width:100%;padding:11px;border:0;border-radius:8px;background:var(--acc);color:#fff;font:inherit;font-weight:600;cursor:pointer}
.err{color:var(--bad);margin-top:10px}
</style></head><body>
<form method="post" autocomplete="on">
  <h1>مراقبة طبخ الكتب</h1>
  <label for="e">البريد</label><input id="e" name="email" type="email" required autocomplete="username">
  <label for="p">كلمة المرور</label><input id="p" name="password" type="password" required autocomplete="current-password">
  <button type="submit">دخول</button>
  <?php if ($error) echo '<div class="err">' . htmlspecialchars($error) . '</div>'; ?>
</form>
</body></html>
