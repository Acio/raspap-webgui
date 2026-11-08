<?php
require_once '../../includes/autoload.php';
require_once '../../includes/CSRF.php';
require_once '../../includes/config.php';
require_once '../../includes/defaults.php';
require_once '../../includes/session.php';
require_once '../../includes/authenticate.php';
require_once '../../includes/functions.php';

use RaspAP\Networking\Hotspot\HotspotReset;
use RaspAP\System\ConfigFile;

\RaspAP\Tokens\CSRF::requirePost();

// Hardened fork: the reset installs the default hotspot configuration for
// the hotspot interface of the device (WifiInterface of hostapd.ini), not
// for wlan0. The other interfaces (for example the uplink) keep their
// dhcpcd blocks and dnsmasq files. HotspotReset saves the current files
// first, and ConfigFile::installAll puts the old files back when a step fails.

function resetResult(int $return, string $message): void
{
    echo json_encode(['return' => $return, 'message' => $message]);
    exit;
}

$path = '../../config';
$iface = HotspotReset::apInterface(@parse_ini_file(RASPI_CONFIG . '/hostapd.ini'), RASPI_WIFI_AP_INTERFACE);
$defaults = json_decode((string)@file_get_contents(RASPI_CONFIG_NETWORK), true);
if (!is_array($defaults)) {
    $defaults = json_decode((string)file_get_contents($path . '/defaults.json'), true) ?: [];
}
$net = HotspotReset::defaults($defaults, $iface);

$read = function (string $file): ?string {
    $content = @file_get_contents($file);
    return $content === false ? null : $content;
};
$template = fn(string $file): string => (string)file_get_contents($path . '/' . $file);
$current = [
    'hostapd.conf' => $read(RASPI_HOSTAPD_CONFIG),
    'dhcpcd.conf' => $read(RASPI_DHCPCD_CONFIG),
    '090_' . $iface . '.conf' => $read(RASPI_DNSMASQ_PREFIX . $iface . '.conf'),
    '090_raspap.conf' => $read(RASPI_DNSMASQ_PREFIX . 'raspap.conf'),
];
// kind, name, new content, old content (for the rollback)
$files = [
    ['hostapd', null, HotspotReset::hostapd($template('hostapd.conf'), $iface, $current['hostapd.conf']), $current['hostapd.conf']],
    ['dhcpcd', null, HotspotReset::dhcpcd($current['dhcpcd.conf'], $template('dhcpcd.conf'), $iface, $net['dhcp']), $current['dhcpcd.conf']],
    ['dnsmasq', $iface, HotspotReset::dnsmasq($template('090_wlan0.conf'), $iface, $net['range']), $current['090_' . $iface . '.conf']],
    ['dnsmasq', 'raspap', $template('090_raspap.conf'), $current['090_raspap.conf']],
];

$backup = HotspotReset::saveBackup(RASPI_CONFIG . '/backups', $current);
if ($backup === null) {
    resetResult(1, 'Unable to save the current configuration. Nothing changed.');
}
if (!ConfigFile::installAll($files)) {
    resetResult(1, 'The reset failed, the old configuration stays: ' . ConfigFile::$lastError);
}
resetResult(0, sprintf('Reset of the hotspot on %s done. Saved the old files in %s.', $iface, $backup));
