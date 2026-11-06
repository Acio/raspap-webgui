<?php
require_once '../../includes/autoload.php';
require_once '../../includes/CSRF.php';
require_once '../../includes/session.php';
require_once '../../includes/config.php';
require_once '../../includes/authenticate.php';

$pluginInstaller = \RaspAP\Plugins\PluginInstaller::getInstance();
// only the name: the source, the version and the install path come from the
// plugin list of this release
$plugin_name = $_POST['plugin_name'] ?? null;

if (is_string($plugin_name) && $plugin_name !== '') {
    try {
        $return = $pluginInstaller->installPluginByName($plugin_name);
        echo json_encode($return);
    } catch (Exception $e) {
        http_response_code(422); // unprocessable content
        echo json_encode(['error' => $e->getMessage()]);
    }
} else {
    http_response_code(400); // Bad Request
    echo json_encode(['error' => 'Plugin name is required']);
    exit;
}
