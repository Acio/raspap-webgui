<?php

/**
 * Hotspot reset (hardened fork)
 *
 * @description Builds the default hotspot configuration for the hotspot
 *              interface of the device (WifiInterface of hostapd.ini), not
 *              for wlan0. The blocks of the other interfaces in dhcpcd.conf
 *              (for example the uplink) and their dnsmasq files stay.
 * @license     https://github.com/raspap/raspap-webgui/blob/master/LICENSE
 */

declare(strict_types=1);

namespace RaspAP\Networking\Hotspot;

class HotspotReset
{
    private const IFACE = '/^[A-Za-z0-9][A-Za-z0-9_.-]{0,14}$/D';

    /**
     * Returns the hotspot interface: WifiInterface of hostapd.ini, else $fallback
     *
     * @param array|false|null $ini the result of parse_ini_file(hostapd.ini)
     * @param string $fallback
     * @return string
     */
    public static function apInterface($ini, string $fallback = 'wlan0'): string
    {
        $iface = is_array($ini) ? (string)($ini['WifiInterface'] ?? '') : '';
        return preg_match(self::IFACE, $iface) ? $iface : $fallback;
    }

    /**
     * The default hostapd.conf for $iface. The country code of the current
     * configuration stays (it sets the legal channels and power).
     *
     * @param string $template config/hostapd.conf
     * @param string $iface
     * @param string|null $current the current hostapd.conf
     * @return string
     */
    public static function hostapd(string $template, string $iface, ?string $current): string
    {
        $conf = preg_replace('/^interface=.*$/m', 'interface=' . $iface, $template, 1);
        if ($current !== null && preg_match('/^country_code=([A-Z]{2})\s*$/m', $current, $m)) {
            $conf = preg_replace('/^country_code=.*$/m', 'country_code=' . $m[1], $conf, 1);
        }
        return $conf;
    }

    /**
     * Removes the block of $iface from a dhcpcd.conf: from its "# RaspAP
     * <iface> configuration" line or its "interface <iface>" line up to the
     * next interface, ssid or "# RaspAP" line
     *
     * @param string $conf
     * @param string $iface
     * @return string
     */
    public static function removeBlock(string $conf, string $iface): string
    {
        $out = [];
        $skip = false;
        $lines = preg_split('/\R/', $conf);
        foreach ($lines as $i => $line) {
            $header = preg_match('/^#\s*RaspAP\s+(\S+)\s+configuration/', $line, $h);
            $start = preg_match('/^\s*(interface|ssid)\s+(\S+)/', $line, $s);
            if ($header || $start) {
                $name = $header ? $h[1] : ($s[1] === 'interface' ? $s[2] : null);
                // a header line belongs to the interface line that follows it
                if ($start || !$skip || $name !== $iface) {
                    $skip = ($name === $iface);
                }
            }
            if (!$skip) {
                $out[] = $line;
            }
        }
        return rtrim(implode("\n", $out)) . "\n";
    }

    /**
     * The dhcpcd.conf with the default block of $iface. The blocks of the
     * other interfaces stay.
     *
     * @param string|null $current the current dhcpcd.conf
     * @param string $template config/dhcpcd.conf (global part and a wlan0 block)
     * @param string $iface
     * @param array $net static ip_address, static routers, static domain_name_servers, subnetmask
     * @return string
     */
    public static function dhcpcd(?string $current, string $template, string $iface, array $net): string
    {
        $base = ($current !== null && trim($current) !== '')
            ? self::removeBlock($current, $iface)
            : self::removeBlock($template, 'wlan0');
        $block = [
            '# RaspAP ' . $iface . ' configuration',
            'interface ' . $iface,
            'static ip_address=' . $net['static ip_address'] . '/' . self::prefix($net['subnetmask']),
            'static routers=' . $net['static routers'],
            'static domain_name_servers=' . $net['static domain_name_servers'],
            'nogateway',
        ];
        return rtrim($base) . "\n\n" . implode("\n", $block) . "\n";
    }

    /**
     * The dnsmasq file of $iface (090_<iface>.conf)
     *
     * @param string $template config/090_wlan0.conf
     * @param string $iface
     * @param string $range the dhcp-range of the interface
     * @return string
     */
    public static function dnsmasq(string $template, string $iface, string $range): string
    {
        $conf = preg_replace('/^# RaspAP wlan0 configuration.*$/m', '# RaspAP ' . $iface . ' configuration', $template, 1);
        $conf = preg_replace('/^interface=.*$/m', 'interface=' . $iface, $conf, 1);
        return preg_replace('/^dhcp-range=.*$/m', 'dhcp-range=' . $range, $conf, 1);
    }

    /**
     * The defaults of $iface from defaults.json, else the defaults of wlan0
     *
     * @param array $defaults the decoded defaults.json
     * @param string $iface
     * @return array ['dhcp' => [...], 'range' => string]
     */
    public static function defaults(array $defaults, string $iface): array
    {
        $dhcp = [];
        foreach (['static ip_address', 'static routers', 'static domain_name_servers', 'subnetmask'] as $key) {
            $dhcp[$key] = (string)($defaults['dhcp'][$iface][$key][0] ?? $defaults['dhcp']['wlan0'][$key][0] ?? '');
        }
        $range = (string)($defaults['dnsmasq'][$iface]['dhcp-range'][0] ?? $defaults['dnsmasq']['wlan0']['dhcp-range'][0] ?? '');
        return ['dhcp' => $dhcp, 'range' => $range];
    }

    /**
     * Prefix length of a dotted subnet mask, for example 24 for 255.255.255.0
     *
     * @param string $mask
     * @return int
     */
    public static function prefix(string $mask): int
    {
        $long = ip2long($mask);
        return $long === false ? 24 : substr_count(decbin($long), '1');
    }
}
