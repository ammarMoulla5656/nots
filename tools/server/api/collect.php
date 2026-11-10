<?php
// Takes a report from the app: how it is used on one device, with the
// messages (books to add, problems) written there. Each report is the whole
// picture of the device, so it replaces the one before.

declare(strict_types=1);
require __DIR__ . '/lib.php';

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') reply(['error' => 'post'], 405);
if (($_SERVER['HTTP_X_NOTS_KEY'] ?? '') !== APP_KEY) reply(['error' => 'key'], 403);

$raw = file_get_contents('php://input', false, null, 0, 4 * 1024 * 1024);
if ($raw === false || $raw === '') reply(['error' => 'empty'], 400);
$json = @gzdecode($raw);
if ($json === false) $json = $raw; // sent plain
$r = json_decode($json, true);
if (!is_array($r)) reply(['error' => 'json'], 400);

$dev = $r['device'] ?? [];
$id = strtolower((string)($dev['id'] ?? ''));
if (!preg_match('/^[0-9a-f]{32}$/', $id)) reply(['error' => 'device'], 400);

$acc = $r['account'] ?? [];
$email = clip(strtolower((string)($acc['email'] ?? '')), 200);
if ($email !== null && !filter_var($email, FILTER_VALIDATE_EMAIL)) $email = null;
$name = clip($acc['name'] ?? null, 120);
$person = $email ?? ('dev:' . $id);

$ip = client_ip();
$cc = country_of($ip);
$now = now_ms();

$db = db();
$db->beginTransaction();
try {
  $old = $db->prepare('SELECT first, reports FROM devices WHERE id = ?');
  $old->execute([$id]);
  $was = $old->fetch();
  $q = $db->prepare('REPLACE INTO devices
    (id, person, email, name, first, last, ip, country, model, android, app, reports, report)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)');
  $q->execute([
    $id, $person, $email, $name,
    $was ? (int)$was['first'] : $now, $now, $ip, $cc,
    clip(trim(($dev['maker'] ?? '') . ' ' . ($dev['model'] ?? '')), 120),
    clip($dev['android'] ?? null, 20),
    clip($dev['app'] ?? null, 30),
    ($was ? (int)$was['reports'] : 0) + 1,
    json_encode($r, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES),
  ]);

  $q = $db->prepare('INSERT INTO ips (device, ip, country, first, last) VALUES (?,?,?,?,?)
    ON CONFLICT(device, ip) DO UPDATE SET last = excluded.last, country = excluded.country');
  $q->execute([$id, $ip, $cc, $now, $now]);

  // The reading of each day, as the device counted it.
  $days = $r['usage']['days'] ?? [];
  if (is_array($days)) {
    $q = $db->prepare('REPLACE INTO daily (device, day, read) VALUES (?,?,?)');
    foreach ($days as $day => $s) {
      if (preg_match('/^\d{4}-\d{2}-\d{2}$/', (string)$day) && is_numeric($s)) {
        $q->execute([$id, $day, (float)$s]);
      }
    }
  }

  $msgs = $r['messages'] ?? [];
  if (is_array($msgs)) {
    $q = $db->prepare('INSERT OR IGNORE INTO messages
      (id, device, email, name, kind, text, about, at, received) VALUES (?,?,?,?,?,?,?,?,?)');
    foreach (array_slice($msgs, 0, 50) as $m) {
      $text = clip($m['text'] ?? null, 4000);
      if ($text === null) continue;
      $kind = ($m['kind'] ?? '') === 'book' ? 'book' : 'problem';
      $q->execute([
        $id . ':' . preg_replace('/[^0-9]/', '', (string)($m['id'] ?? '')),
        $id, $email, $name, $kind, $text, clip($m['about'] ?? null, 300),
        (int)($m['at'] ?? $now), $now,
      ]);
    }
  }
  $db->commit();
} catch (Throwable $e) {
  $db->rollBack();
  reply(['error' => 'store'], 500);
}
reply(['ok' => true]);
