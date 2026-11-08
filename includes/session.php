<?php

// Hardened fork: security headers for each PHP page and ajax response.
// The web interface is not shown in a frame of another site, the browser
// does not guess content types, the full URL is not sent to other sites,
// pages can not use the camera, microphone, location, payment or USB,
// and the browser does not keep copies of the pages and responses.
if (!headers_sent()) {
    header('X-Frame-Options: DENY');
    header("Content-Security-Policy: frame-ancestors 'none'; base-uri 'self'; object-src 'none'; form-action 'self'");
    header('X-Content-Type-Options: nosniff');
    header('Referrer-Policy: same-origin');
    header('Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), usb=()');
    header('Cache-Control: no-store, no-cache, must-revalidate');
}

if (session_status() == PHP_SESSION_NONE) {
    // hardened fork: PHP accepts only session ids that it made itself, so a
    // session id from another person can not become a login (session fixation)
    ini_set('session.use_strict_mode', '1');
    // the session cookie: not readable by scripts, not sent with requests
    // from other sites, and only sent over HTTPS when the page uses HTTPS
    session_set_cookie_params([
        'path' => '/',
        'httponly' => true,
        'samesite' => 'Lax',
        'secure' => !empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off',
    ]);
    session_start();
}

if (!isset($_SESSION['lastActivity'])) {
    $_SESSION['lastActivity'] = time();
}
