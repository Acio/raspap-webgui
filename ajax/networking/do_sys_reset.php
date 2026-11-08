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
// dhcpcd blocks and dnsmasq files. The current files are saved first, and a
// failed step puts back the files of the earlier steps.

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
$current = [
    'hostapd' => $read(RASPI_HOSTAPD_CONFIG),
    'dhcpcd' => $read(RASPI_DHCPCD_CONFIG),
    'dnsmasq-iface' => $read(RASPI_DNSMASQ_PREFIX . $iface . '.conf'),
    'dnsmasq-raspap' => $read(RASPI_DNSMASQ_PREFIX . 'raspap.conf'),
];

// kind, name, new content, key of the current content
$steps = [
    ['hostapd', null, HotspotReset::hostapd((string)file_get_contents($path . '/hostapd.conf'), $iface, $current['hostapd']), 'hostapd'],
    ['dhcpcd', null, HotspotReset::dhcpcd($current['dhcpcd'], (string)file_get_contents($path . '/dhcpcd.conf'), $iface, $net['dhcp']), 'dhcpcd'],
    ['dnsmasq', $iface, HotspotReset::dnsmasq((string)file_get_contents($path . '/090_wlan0.conf'), $iface, $net['range']), 'dnsmasq-iface'],
    ['dnsmasq', 'raspap', (string)file_get_contents($path . '/090_raspap.conf'), 'dnsmasq-raspap'],
];

// save the current files: /etc/raspap/backups/reset-<time>, mode 600, the 3 newest stay
// a random part, so two resets in the same second do not use the same directory
$backup = RASPI_CONFIG . '/backups/reset-' . date('Ymd-His') . '-' . bin2hex(random_bytes(3));
$umask = umask(0077);
$saved = @mkdir($backup, 0700);
foreach ($current as $key => $content) {
    if ($saved && $content !== null) {
        $saved = file_put_contents($backup . '/' . $key . '.conf', $content) !== false;
    }
}
umask($umask);
if (!$saved) {
    resetResult(1, 'Unable to save the current configuration. Nothing changed.');
}
$old = glob(RASPI_CONFIG . '/backups/reset-*', GLOB_ONLYDIR) ?: [];
rsort($old);
foreach (array_slice($old, 3) as $dir) {
    array_map('unlink', glob($dir . '/*') ?: []);
    @rmdir($dir);
}

$done = [];
foreach ($steps as [$kind, $name, $content, $key]) {
    if (!ConfigFile::install($kind, $name, $content)) {
        $error = ConfigFile::$lastError;
        // put back the files of the earlier steps
        foreach (array_reverse($done) as [$k, $n, $c]) {
            if ($c !== null) {
                ConfigFile::install($k, $n, $c);
            } elseif ($k === 'dnsmasq') {
                ConfigFile::remove($k, (string)$n);
            }
        }
        resetResult(1, 'The reset failed, the old configuration stays: ' . $error);
    }
    $done[] = [$kind, $name, $current[$key]];
}
resetResult(0, sprintf('Reset of the hotspot on %s done. Saved the old files in %s.', $iface, $backup));
