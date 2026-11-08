<?php

if (RASPI_AUTH_ENABLED) {
    $auth = new \RaspAP\Auth\HTTPAuth;

    // Hardened fork: the server ends a session that was idle for
    // RASPI_SESSION_TIMEOUT seconds. Before, only the JavaScript did this.
    if ($auth->isLogged() && $auth->isIdle()) {
        if (strpos($_SERVER['SCRIPT_NAME'] ?? '', '/ajax/') !== false) {
            session_unset();
            session_destroy();
            http_response_code(401);
            header('Content-Type: application/json');
            echo json_encode(['status' => 'session_expired']);
            exit();
        }
        $auth->logout();
    }

    if (!$auth->isLogged()) {
        $auth->authenticate();
    }
}
