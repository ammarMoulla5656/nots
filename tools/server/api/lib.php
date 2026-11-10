<?php
// Shared by collect.php and admin.php: the database, the country of an
// address, and replies. Everything lives under nots/api/; the data folder
// is closed to the web (its own .htaccess, and the root one denies .sqlite).

declare(strict_types=1);
ini_set('serialize_precision', '-1');

const OWNER = 'ammargmaes1@gmail.com';
const APP_KEY = 'nots-usage-1';

function data_dir(): string {
  return __DIR__ . '/data';
}

function db(): PDO {
  static $db = null;
  if ($db) return $db;
  $path = getenv('NOTS_STATS_DB') ?: data_dir() . '/stats.sqlite';
  $db = new PDO('sqlite:' . $path, null, null, [
    PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
  ]);
  $db->exec('PRAGMA journal_mode=WAL');
  $db->exec('PRAGMA busy_timeout=5000');
  $db->exec('CREATE TABLE IF NOT EXISTS devices (
    id TEXT PRIMARY KEY, person TEXT NOT NULL, email TEXT, name TEXT,
    first INTEGER NOT NULL, last INTEGER NOT NULL, ip TEXT, country TEXT,
    model TEXT, android TEXT, app TEXT, reports INTEGER NOT NULL DEFAULT 0,
    report TEXT NOT NULL)');
  $db->exec('CREATE INDEX IF NOT EXISTS devices_person ON devices(person)');
  $db->exec('CREATE TABLE IF NOT EXISTS ips (
    device TEXT NOT NULL, ip TEXT NOT NULL, country TEXT,
    first INTEGER NOT NULL, last INTEGER NOT NULL, PRIMARY KEY (device, ip))');
  $db->exec('CREATE TABLE IF NOT EXISTS daily (
    device TEXT NOT NULL, day TEXT NOT NULL, read REAL NOT NULL,
    PRIMARY KEY (device, day))');
  $db->exec('CREATE TABLE IF NOT EXISTS messages (
    id TEXT PRIMARY KEY, device TEXT NOT NULL, email TEXT, name TEXT,
    kind TEXT NOT NULL, text TEXT NOT NULL, about TEXT, at INTEGER NOT NULL,
    received INTEGER NOT NULL, done INTEGER NOT NULL DEFAULT 0)');
  $db->exec('CREATE TABLE IF NOT EXISTS admins (
    email TEXT PRIMARY KEY, added INTEGER NOT NULL, by TEXT)');
  $db->exec('CREATE TABLE IF NOT EXISTS tokens (
    hash TEXT PRIMARY KEY, email TEXT NOT NULL, until INTEGER NOT NULL)');
  return $db;
}

/// The country (two letters) of an IPv4 or IPv6 address, from the DB-IP
/// Lite table kept on this server: no address leaves it.
function country_of(string $ip): string {
  $bin = @inet_pton($ip);
  if ($bin === false) return '';
  if (strlen($bin) === 4) $bin = str_repeat("\0", 10) . "\xff\xff" . $bin;
  $path = data_dir() . '/geo.sqlite';
  if (!is_file($path)) return '';
  static $geo = null;
  $geo ??= new PDO('sqlite:' . $path, null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
  $q = $geo->prepare('SELECT cc FROM ip WHERE start <= ? ORDER BY start DESC LIMIT 1');
  $q->bindValue(1, $bin, PDO::PARAM_LOB);
  $q->execute();
  $cc = $q->fetchColumn();
  return ($cc && $cc !== 'ZZ') ? (string)$cc : '';
}

function client_ip(): string {
  return (string)($_SERVER['REMOTE_ADDR'] ?? '');
}

function reply($data, int $code = 200): never {
  http_response_code($code);
  header('Content-Type: application/json; charset=utf-8');
  header('Cache-Control: no-store');
  echo json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
  exit;
}

function now_ms(): int {
  return (int)floor(microtime(true) * 1000);
}

/// Text cut to a sane length (reports come from the app, but still).
function clip($v, int $n = 300): ?string {
  if ($v === null) return null;
  $s = trim((string)$v);
  return $s === '' ? null : mb_substr($s, 0, $n);
}
