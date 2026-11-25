<?php
// The books' Excel file, which the Xeon refreshes every 10 minutes.
require __DIR__ . '/_auth.php';
nots_require_login();
$f = __DIR__ . '/_data/books.xlsx';
if (!is_file($f)) {
    http_response_code(404);
    header('Content-Type: text/plain; charset=utf-8');
    exit('لم يصل ملف Excel من الخادم بعد');
}
header('Content-Type: application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
header('Content-Disposition: attachment; filename="masaha_books_' . date('Ymd_Hi', filemtime($f)) . '.xlsx"');
header('Content-Length: ' . filesize($f));
header('Cache-Control: no-store');
readfile($f);
