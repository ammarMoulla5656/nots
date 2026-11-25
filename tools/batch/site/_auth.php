<?php
// Login for the monitoring page. The password is kept only as a hash
// (password_hash); _config.php is written by the deploy, not kept in git.
declare(strict_types=1);
session_name('nots_monitor');
session_set_cookie_params(['lifetime' => 60 * 60 * 24 * 14, 'path' => dirname($_SERVER['SCRIPT_NAME']) . '/',
                           'secure' => !empty($_SERVER['HTTPS']), 'httponly' => true, 'samesite' => 'Strict']);
session_start();
require __DIR__ . '/_config.php';

function nots_logged_in(): bool {
    return !empty($_SESSION['nots_ok']);
}

function nots_try_login(string $email, string $password): bool {
    $ok = hash_equals(strtolower(NOTS_EMAIL), strtolower(trim($email)))
          && password_verify($password, NOTS_HASH);
    if ($ok) {
        session_regenerate_id(true);
        $_SESSION['nots_ok'] = true;
    } else {
        sleep(2);  // slows down guessing
    }
    return $ok;
}

function nots_require_login(): void {
    if (!nots_logged_in()) {
        http_response_code(401);
        header('Content-Type: text/plain; charset=utf-8');
        exit('login required');
    }
}
