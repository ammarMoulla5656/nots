<?php
// The administrators' view of the statistics. Every request carries the
// Google Drive access token of the account signed in on the app; Google
// tells which account it is, and only administrators get an answer.

declare(strict_types=1);
require __DIR__ . '/lib.php';

/// The email of the Google account behind [token], asked of Google (Drive's
/// "about", which the app's own permission allows), kept for half an hour.
function email_of_token(string $token): ?string {
  $db = db();
  $hash = hash('sha256', $token);
  $q = $db->prepare('SELECT email FROM tokens WHERE hash = ? AND until > ?');
  $q->execute([$hash, time()]);
  $hit = $q->fetchColumn();
  if ($hit) return (string)$hit;
  $c = curl_init('https://www.googleapis.com/drive/v3/about?fields=user(emailAddress)');
  curl_setopt_array($c, [
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_TIMEOUT => 15,
    CURLOPT_HTTPHEADER => ['Authorization: Bearer ' . $token],
  ]);
  $body = curl_exec($c);
  $code = curl_getinfo($c, CURLINFO_HTTP_CODE);
  curl_close($c);
  if ($code !== 200 || !is_string($body)) return null;
  $email = strtolower((string)(json_decode($body, true)['user']['emailAddress'] ?? ''));
  if ($email === '') return null;
  $db->prepare('DELETE FROM tokens WHERE until < ?')->execute([time()]);
  $db->prepare('REPLACE INTO tokens (hash, email, until) VALUES (?,?,?)')
    ->execute([$hash, $email, time() + 1800]);
  return $email;
}

function is_admin(string $email): bool {
  if ($email === OWNER) return true;
  $q = db()->prepare('SELECT 1 FROM admins WHERE email = ?');
  $q->execute([$email]);
  return (bool)$q->fetchColumn();
}

// ---------------------------------------------------------------- reading

/// Every device with its last report decoded.
function devices(): array {
  $out = [];
  foreach (db()->query('SELECT * FROM devices') as $row) {
    $row['r'] = json_decode($row['report'], true) ?: [];
    unset($row['report']);
    $out[] = $row;
  }
  return $out;
}

function add_map(array &$into, $from): void {
  if (!is_array($from)) return;
  foreach ($from as $k => $v) {
    if (is_numeric($v)) $into[$k] = ($into[$k] ?? 0) + $v;
  }
}

function add_list(array &$into, $from, int $n): void {
  if (count($into) !== $n) $into = array_fill(0, $n, 0);
  if (!is_array($from)) return;
  for ($i = 0; $i < $n; $i++) $into[$i] += (float)($from[$i] ?? 0);
}

function top(array $m, int $n = 0): array {
  arsort($m);
  return $n ? array_slice($m, 0, $n, true) : $m;
}

/// The library catalogue: id → title, author, subject.
function catalog_titles(): array {
  static $t = null;
  if ($t !== null) return $t;
  $t = [];
  $raw = @file_get_contents(__DIR__ . '/../catalog.txt');
  $j = $raw ? json_decode($raw, true) : null;
  foreach (($j['books'] ?? []) as $b) {
    $t[$b['id']] = ['t' => $b['title'] ?? '', 'a' => $b['author'] ?? '', 's' => $b['subject'] ?? ''];
  }
  return $t;
}

function overview(array $devs): array {
  $now = now_ms();
  $day = 86400000;
  $persons = [];
  $tools = $features = $network = $apps = $androids = $models = $countries = [];
  $hours = $clean = $weekdays = [];
  $read = 0.0; $cleanTotal = 0.0; $cleanUsers = 0; $linked = 0; $bytes = 0; $items = 0;
  foreach ($devs as $d) {
    $p = $d['person'];
    $persons[$p] ??= ['last' => 0, 'first' => PHP_INT_MAX, 'email' => $d['email'], 'cc' => '', 'read' => 0];
    $pp = &$persons[$p];
    if ($d['last'] > $pp['last']) { $pp['last'] = (int)$d['last']; $pp['cc'] = $d['country']; }
    $pp['first'] = min($pp['first'], (int)$d['first']);
    $u = $d['r']['usage'] ?? [];
    $tot = $u['tot'] ?? [];
    $pp['read'] += (float)($tot['read'] ?? 0);
    unset($pp);
    $read += (float)($tot['read'] ?? 0);
    $c = (float)($tot['clean'] ?? 0);
    $cleanTotal += $c;
    if ($c > 0) $cleanUsers++;
    add_map($tools, $u['tools'] ?? []);
    add_map($features, $u['f'] ?? []);
    add_list($hours, $u['hours'] ?? [], 24);
    add_list($clean, $u['cleanHours'] ?? [], 24);
    add_list($weekdays, $u['weekdays'] ?? [], 7);
    foreach (['wifi', 'mobile', 'offline'] as $k) $network[$k] = ($network[$k] ?? 0) + (float)($tot[$k] ?? 0);
    if (!empty($d['r']['account']['linked'])) $linked++;
    $apps[$d['app'] ?: '?'] = ($apps[$d['app'] ?: '?'] ?? 0) + 1;
    $androids[$d['android'] ?: '?'] = ($androids[$d['android'] ?: '?'] ?? 0) + 1;
    $models[$d['model'] ?: '?'] = ($models[$d['model'] ?: '?'] ?? 0) + 1;
    $bytes += (int)($d['r']['library']['bytes'] ?? 0);
    $items += (int)($d['r']['library']['items'] ?? 0);
  }
  $active = fn(int $days) => count(array_filter($persons, fn($p) => $p['last'] > $now - $days * $day));
  foreach ($persons as $p) {
    $k = $p['cc'] ?: '؟';
    $countries[$k] = ($countries[$k] ?? 0) + 1;
  }
  // The last 30 days: who read, and how long.
  $since = date('Y-m-d', time() - 30 * 86400);
  $daily = [];
  $q = db()->prepare('SELECT d.day, COUNT(DISTINCT v.person) n, SUM(d.read) s
    FROM daily d JOIN devices v ON v.id = d.device WHERE d.day >= ? GROUP BY d.day ORDER BY d.day');
  $q->execute([$since]);
  foreach ($q as $row) $daily[] = ['day' => $row['day'], 'users' => (int)$row['n'], 'hours' => round($row['s'] / 3600, 1)];
  $open = (int)db()->query('SELECT COUNT(*) FROM messages WHERE done = 0')->fetchColumn();
  $n = max(1, count($persons));
  return [
    'users' => count($persons),
    'devices' => count($devs),
    'signedIn' => count(array_filter($persons, fn($p) => !empty($p['email']))),
    'syncDevices' => $linked,
    'active' => ['day' => $active(1), 'week' => $active(7), 'month' => $active(30)],
    'newWeek' => count(array_filter($persons, fn($p) => $p['first'] > $now - 7 * $day)),
    'readHours' => round($read / 3600, 1),
    'hoursPerUser' => round($read / 3600 / $n, 1),
    'cleanHours' => round($cleanTotal / 3600, 1),
    'cleanUsers' => $cleanUsers,
    'countries' => top($countries),
    'tools' => top($tools),
    'features' => top($features),
    'hours' => array_map(fn($s) => round($s / 3600, 1), $hours ?: array_fill(0, 24, 0)),
    'cleanByHour' => array_map(fn($s) => round($s / 3600, 1), $clean ?: array_fill(0, 24, 0)),
    'weekdays' => array_map(fn($s) => round($s / 3600, 1), $weekdays ?: array_fill(0, 7, 0)),
    'network' => array_map(fn($s) => round($s / 3600, 1), $network),
    'apps' => top($apps), 'androids' => top($androids), 'models' => top($models, 12),
    'avgLibraryMB' => round($bytes / 1048576 / max(1, count($devs)), 1),
    'avgItems' => round($items / max(1, count($devs)), 1),
    'daily' => $daily,
    'openMessages' => $open,
  ];
}

function books(array $devs): array {
  $cat = catalog_titles();
  $b = [];
  $own = [];
  $touch = function (string $c) use (&$b, $cat) {
    $b[$c] ??= [
      'id' => $c, 't' => $cat[$c]['t'] ?? '', 'a' => $cat[$c]['a'] ?? '', 's' => $cat[$c]['s'] ?? '',
      'holders' => [], 'readers' => [], 'downloads' => 0, 'views' => 0, 'hours' => 0.0, 'progress' => [],
    ];
  };
  foreach ($devs as $d) {
    $p = $d['person'];
    $r = $d['r'];
    foreach (($r['library']['catalog'] ?? []) as $x) {
      $c = (string)($x['c'] ?? '');
      if ($c === '') continue;
      $touch($c);
      $b[$c]['holders'][$p] = true;
    }
    foreach (($r['usage']['catalog'] ?? []) as $c => $m) {
      $touch((string)$c);
      $b[$c]['downloads'] += (int)($m['dl'] ?? 0);
      $b[$c]['views'] += (int)($m['view'] ?? 0);
    }
    foreach (($r['usage']['books'] ?? []) as $x) {
      $c = (string)($x['c'] ?? '');
      if ($c !== '') {
        $touch($c);
        if ($b[$c]['t'] === '') $b[$c]['t'] = (string)($x['t'] ?? '');
        $s = (float)($x['s'] ?? 0);
        $b[$c]['hours'] += $s / 3600;
        if ($s >= 60) $b[$c]['readers'][$p] = true;
        $n = (int)($x['n'] ?? 0);
        if ($n > 0) $b[$c]['progress'][] = min(1, max((int)($x['far'] ?? 0), (int)($x['pg'] ?? 0)) / $n);
      }
    }
    foreach (($r['library']['ownBooks'] ?? []) as $x) {
      $t = trim((string)($x['t'] ?? ''));
      if ($t === '') continue;
      $own[$t] ??= ['t' => $t, 'a' => (string)($x['a'] ?? ''), 'users' => []];
      $own[$t]['users'][$p] = true;
    }
  }
  $list = [];
  foreach ($b as $x) {
    $holders = count($x['holders']);
    $readers = count($x['readers']);
    $list[] = [
      'id' => $x['id'], 't' => $x['t'] ?: $x['id'], 'a' => $x['a'], 's' => $x['s'],
      'holders' => $holders, 'readers' => $readers,
      'downloads' => max($x['downloads'], $holders), 'views' => $x['views'],
      'hours' => round($x['hours'], 1),
      'progress' => $x['progress'] ? round(array_sum($x['progress']) / count($x['progress']) * 100) : 0,
      'use' => $holders ? round($readers / $holders * 100) : 0,
    ];
  }
  usort($list, fn($a, $b) => [$b['readers'], $b['hours'], $b['downloads']] <=> [$a['readers'], $a['hours'], $a['downloads']]);
  $ownList = array_values(array_map(fn($x) => ['t' => $x['t'], 'a' => $x['a'], 'users' => count($x['users'])], $own));
  usort($ownList, fn($a, $b) => $b['users'] <=> $a['users']);
  return ['books' => $list, 'own' => array_slice($ownList, 0, 300)];
}

function users(array $devs): array {
  $p = [];
  foreach ($devs as $d) {
    $k = $d['person'];
    $r = $d['r'];
    $p[$k] ??= ['key' => $k, 'email' => $d['email'], 'name' => $d['name'], 'cc' => '', 'devices' => 0,
      'first' => PHP_INT_MAX, 'last' => 0, 'hours' => 0.0, 'items' => 0, 'own' => 0, 'sync' => false, 'app' => ''];
    $u = &$p[$k];
    $u['devices']++;
    $u['first'] = min($u['first'], (int)$d['first']);
    if ($d['last'] > $u['last']) {
      $u['last'] = (int)$d['last']; $u['cc'] = $d['country']; $u['app'] = $d['app'];
      $u['name'] = $d['name'] ?: $u['name'];
    }
    $u['hours'] += (float)($r['usage']['tot']['read'] ?? 0) / 3600;
    $u['items'] = max($u['items'], (int)($r['library']['items'] ?? 0));
    $u['own'] = max($u['own'], (int)($r['library']['own'] ?? 0));
    $u['sync'] = $u['sync'] || !empty($r['account']['linked']);
    if (!$u['name']) $u['name'] = $d['model'];
    unset($u);
  }
  $list = array_values($p);
  foreach ($list as &$u) $u['hours'] = round($u['hours'], 1);
  unset($u);
  usort($list, fn($a, $b) => $b['last'] <=> $a['last']);
  return $list;
}

function user(array $devs, string $key): array {
  $mine = array_values(array_filter($devs, fn($d) => $d['person'] === $key));
  if (!$mine) reply(['error' => 'none'], 404);
  $tot = $tools = $features = $hours = $clean = $weekdays = $settings = [];
  $books = [];
  $own = [];
  $devices = [];
  foreach ($mine as $d) {
    $r = $d['r'];
    $u = $r['usage'] ?? [];
    add_map($tot, $u['tot'] ?? []);
    add_map($tools, $u['tools'] ?? []);
    add_map($features, $u['f'] ?? []);
    add_list($hours, $u['hours'] ?? [], 24);
    add_list($clean, $u['cleanHours'] ?? [], 24);
    add_list($weekdays, $u['weekdays'] ?? [], 7);
    $settings = ($r['settings'] ?? []) + $settings;
    foreach (($u['books'] ?? []) as $id => $x) {
      $books[$id] = isset($books[$id]) ? merge_book($books[$id], $x) : $x;
    }
    foreach (($r['library']['ownBooks'] ?? []) as $x) $own[$x['t'] ?? ''] = $x;
    $ips = db()->prepare('SELECT ip, country, first, last FROM ips WHERE device = ? ORDER BY last DESC LIMIT 20');
    $ips->execute([$d['id']]);
    $dev = $r['device'] ?? [];
    $devices[] = [
      'id' => $d['id'], 'model' => $d['model'], 'android' => $d['android'], 'app' => $d['app'],
      'first' => (int)$d['first'], 'last' => (int)$d['last'], 'reports' => (int)$d['reports'],
      'ip' => $d['ip'], 'cc' => $d['country'], 'ips' => $ips->fetchAll(),
      'hz' => $dev['hz'] ?? null, 'screen' => $dev['screen'] ?? null, 'lang' => $dev['lang'] ?? null,
      'freeMB' => isset($dev['free']) ? round($dev['free'] / 1048576) : null,
      'totalMB' => isset($dev['total']) ? round($dev['total'] / 1048576) : null,
      'library' => $r['library'] ?? [], 'linked' => !empty($r['account']['linked']),
    ];
  }
  $cat = catalog_titles();
  $list = [];
  foreach ($books as $id => $x) {
    $c = (string)($x['c'] ?? '');
    $list[] = [
      'id' => $id, 't' => $x['t'] ?? ($cat[$c]['t'] ?? ''), 'a' => $x['a'] ?? '',
      'kind' => !empty($x['note']) ? 'note' : (!empty($x['own']) ? 'own' : 'library'),
      'hours' => round((float)($x['s'] ?? 0) / 3600, 2), 'opens' => (int)($x['o'] ?? 0),
      'page' => (int)($x['pg'] ?? 0), 'far' => (int)($x['far'] ?? 0), 'pages' => (int)($x['n'] ?? 0),
      'last' => (int)($x['last'] ?? 0), 'tools' => top($x['tools'] ?? []), 'f' => top($x['f'] ?? []),
    ];
  }
  usort($list, fn($a, $b) => $b['hours'] <=> $a['hours']);
  $msgs = db()->prepare('SELECT kind, text, about, at, done FROM messages WHERE device IN (' .
    implode(',', array_fill(0, count($mine), '?')) . ') ORDER BY at DESC');
  $msgs->execute(array_column($mine, 'id'));
  $daily = db()->prepare('SELECT day, SUM(read) s FROM daily WHERE device IN (' .
    implode(',', array_fill(0, count($mine), '?')) . ') GROUP BY day ORDER BY day DESC LIMIT 60');
  $daily->execute(array_column($mine, 'id'));
  $h = fn($s) => round($s / 3600, 2);
  return [
    'key' => $key, 'email' => $mine[0]['email'], 'name' => $mine[0]['name'],
    'devices' => $devices,
    'totals' => [
      'readHours' => $h($tot['read'] ?? 0), 'appHours' => $h($tot['app'] ?? 0),
      'cleanHours' => $h($tot['clean'] ?? 0), 'wifiHours' => $h($tot['wifi'] ?? 0),
      'mobileHours' => $h($tot['mobile'] ?? 0), 'offlineHours' => $h($tot['offline'] ?? 0),
      'sessions' => (int)($tot['sessions'] ?? 0), 'opens' => (int)($tot['opens'] ?? 0),
      'launches' => (int)($tot['launches'] ?? 0),
    ],
    'hours' => array_map($h, $hours), 'cleanByHour' => array_map($h, $clean), 'weekdays' => array_map($h, $weekdays),
    'tools' => top($tools), 'features' => top($features), 'settings' => $settings,
    'books' => $list, 'own' => array_values($own),
    'daily' => array_map(fn($r) => ['day' => $r['day'], 'hours' => $h($r['s'])], $daily->fetchAll()),
    'messages' => $msgs->fetchAll(),
  ];
}

function merge_book(array $a, array $b): array {
  $a['s'] = ($a['s'] ?? 0) + ($b['s'] ?? 0);
  $a['o'] = ($a['o'] ?? 0) + ($b['o'] ?? 0);
  $a['far'] = max($a['far'] ?? 0, $b['far'] ?? 0);
  if (($b['last'] ?? 0) > ($a['last'] ?? 0)) { $a['pg'] = $b['pg'] ?? 0; $a['last'] = $b['last']; }
  $a['n'] = max($a['n'] ?? 0, $b['n'] ?? 0);
  foreach (['tools', 'f'] as $g) {
    $m = $a[$g] ?? [];
    add_map($m, $b[$g] ?? []);
    $a[$g] = $m;
  }
  return $a;
}

// ---------------------------------------------------------------- serving

if (!defined('NOTS_TEST')) {
  $auth = (string)($_SERVER['HTTP_AUTHORIZATION'] ?? $_SERVER['REDIRECT_HTTP_AUTHORIZATION'] ?? '');
  if ($auth === '' && function_exists('getallheaders')) {
    foreach (getallheaders() as $k => $v) if (strcasecmp($k, 'Authorization') === 0) $auth = $v;
  }
  $token = preg_match('/^Bearer\s+(\S+)$/', $auth, $m) ? $m[1] : '';
  // Some servers drop the Authorization header before PHP sees it.
  if ($token === '') $token = trim((string)($_SERVER['HTTP_X_NOTS_TOKEN'] ?? ''));
  $email = $token === '' ? null : email_of_token($token);
  if ($email === null) reply(['error' => 'sign-in'], 401);
  $admin = is_admin($email);
  $a = (string)($_GET['a'] ?? '');
  if ($a === 'whoami') reply(['email' => $email, 'admin' => $admin, 'owner' => $email === OWNER]);
  if (!$admin) reply(['error' => 'not an administrator'], 403);
  serve($a, $email);
}

function serve(string $a, string $email): never {
  $db = db();
  switch ($a) {
    case 'overview': reply(overview(devices()));
    case 'books': reply(books(devices()));
    case 'users': reply(users(devices()));
    case 'user': reply(user(devices(), (string)($_GET['id'] ?? '')));
    case 'messages':
      reply($db->query('SELECT m.*, v.country cc, v.model FROM messages m LEFT JOIN devices v ON v.id = m.device
        ORDER BY m.done, m.at DESC LIMIT 500')->fetchAll());
    case 'done':
      $db->prepare('UPDATE messages SET done = ? WHERE id = ?')
        ->execute([($_GET['v'] ?? '1') === '0' ? 0 : 1, (string)($_GET['id'] ?? '')]);
      reply(['ok' => true]);
    case 'admins':
      reply(['owner' => OWNER, 'admins' => $db->query('SELECT email, added, by FROM admins ORDER BY added')->fetchAll()]);
    case 'addAdmin':
    case 'removeAdmin':
      if ($email !== OWNER) reply(['error' => 'only the owner'], 403);
      $who = strtolower(trim((string)($_GET['email'] ?? '')));
      if (!filter_var($who, FILTER_VALIDATE_EMAIL) || $who === OWNER) reply(['error' => 'email'], 400);
      if ($a === 'addAdmin') {
        $db->prepare('INSERT OR IGNORE INTO admins (email, added, by) VALUES (?,?,?)')->execute([$who, now_ms(), $email]);
      } else {
        $db->prepare('DELETE FROM admins WHERE email = ?')->execute([$who]);
      }
      reply(['ok' => true]);
  }
  reply(['error' => 'unknown'], 400);
}
