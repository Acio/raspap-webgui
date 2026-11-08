<?php
require_once '../../includes/autoload.php';
require_once '../../includes/CSRF.php';
require_once '../../includes/session.php';
require_once '../../includes/config.php';
require_once '../../includes/authenticate.php';

// Hardened fork: compares the hotspot channel with the channel of the
// wireless uplink. The uplink channel changes when the device connects to
// another network, so the web interface asks this at runtime.

// accept POST only, so the CSRF token is always verified
if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    http_response_code(405);
    header('Allow: POST');
    exit;
}
session_write_close();
header('Content-Type: application/json');

$ini = @parse_ini_file(RASPI_CONFIG . '/hostapd.ini');
$apIface = is_array($ini) && !empty($ini['WifiInterface']) ? (string)$ini['WifiInterface'] : null;

echo json_encode(\RaspAP\Networking\ChannelOverlap::run($apIface));
