<?php

/**
 * Channel overlap check (hardened fork)
 *
 * @description Compares the frequencies of the hotspot with the frequencies
 *              of the wireless uplink. Two radios of one device that use the
 *              same or near frequencies disturb each other: traffic through
 *              the hotspot needs both radios at the same time.
 * @license     https://github.com/raspap/raspap-webgui/blob/master/LICENSE
 */

declare(strict_types=1);

namespace RaspAP\Networking;

class ChannelOverlap
{
    // two ranges that are less than this many MHz apart are "close"
    public const CLOSE_MHZ = 40;

    // a suggested channel this many MHz or more from the uplink is "far"
    public const FAR_MHZ = 100;

    // center channels of the 5 GHz blocks for each width (hostapd seg0 index)
    private const CENTERS_5GHZ = [
        40 => [38, 46, 54, 62, 102, 110, 118, 126, 134, 142, 151, 159, 167],
        80 => [42, 58, 106, 122, 138, 155, 171],
        160 => [50, 114, 163],
    ];

    /**
     * Parses the output of `iw dev`
     *
     * @param string $out
     * @return array one entry for each interface with a type
     */
    public static function parseIwDev(string $out): array
    {
        $interfaces = [];
        $phy = null;
        $current = null;
        foreach (preg_split('/\R/', $out) as $line) {
            if (preg_match('/^phy#(\d+)\s*$/', $line, $m)) {
                $phy = 'phy' . $m[1];
                $current = null;
            } elseif (preg_match('/^\s+Interface\s+(\S+)\s*$/', $line, $m)) {
                $interfaces[$m[1]] = ['iface' => $m[1], 'phy' => $phy, 'type' => null, 'channel' => null];
                $current = $m[1];
            } elseif (preg_match('/^\s+Unnamed\/non-netdev interface/', $line)) {
                $current = null;
            } elseif ($current !== null && preg_match('/^\s+type\s+(.+?)\s*$/', $line, $m)) {
                $interfaces[$current]['type'] = $m[1];
            } elseif ($current !== null &&
                preg_match('/^\s+channel\s+(\d+)\s+\((\d+)(?:\.\d+)? MHz\),\s+width:\s+(\d+)(\+80)? MHz[^,]*(?:,\s+center1:\s+(\d+) MHz)?(?:,\s+center2:\s+(\d+) MHz)?/', $line, $m)) {
                $freq = (int)$m[2];
                $width = (int)$m[3];
                $c1 = isset($m[5]) && $m[5] !== '' ? (int)$m[5] : $freq;
                $ranges = [[$c1 - intdiv($width, 2), $c1 + intdiv($width, 2)]];
                $label = $width . ' MHz';
                if (!empty($m[4]) && !empty($m[6])) {
                    // 80+80 MHz: a second segment
                    $c2 = (int)$m[6];
                    $ranges[] = [$c2 - 40, $c2 + 40];
                    $label = '80+80 MHz';
                }
                $interfaces[$current]['channel'] = (int)$m[1];
                $interfaces[$current]['freq'] = $freq;
                $interfaces[$current]['width'] = $width;
                $interfaces[$current]['widthLabel'] = $label;
                $interfaces[$current]['ranges'] = $ranges;
            }
        }
        return array_values($interfaces);
    }

    /**
     * Returns the distance in MHz between two sets of ranges. A negative
     * value means that the ranges overlap.
     *
     * @param array $a
     * @param array $b
     * @return int
     */
    public static function gap(array $a, array $b): int
    {
        $min = PHP_INT_MAX;
        foreach ($a as [$alo, $ahi]) {
            foreach ($b as [$blo, $bhi]) {
                $min = min($min, max($blo - $ahi, $alo - $bhi));
            }
        }
        return $min;
    }

    /**
     * Parses the frequencies of `iw phy <phy> info` that an access point can
     * use: not disabled, no radar detection and no "no IR"
     *
     * @param string $out
     * @return array MHz => dBm
     */
    public static function parseFrequencies(string $out): array
    {
        $freqs = [];
        preg_match_all('/^\s+\*\s+(\d+)(?:\.\d+)?\s+MHz\s+\[(\d+)\]\s+(.*)$/m', $out, $matches, PREG_SET_ORDER);
        foreach ($matches as $m) {
            if (preg_match('/disabled|radar|no IR/', $m[3]) || !preg_match('/\(([\d.]+) dBm\)/', $m[3], $p)) {
                continue;
            }
            $freqs[(int)$m[1]] = (float)$p[1];
        }
        return $freqs;
    }

    /**
     * Returns the candidate channel blocks of the band of $freq for $width
     *
     * @param int $freq a frequency of the band
     * @param int $width
     * @return array of ['channel' => primary channel, 'members' => [MHz], 'range' => [lo, hi]]
     */
    private static function candidates(int $freq, int $width): array
    {
        $blocks = [];
        if ($freq >= 2400 && $freq < 2500) {
            // 2.4 GHz: 20 MHz, or 40 MHz as the primary channel and the channel 4 above it
            for ($ch = 1; $ch <= 13; $ch++) {
                $f = 2407 + 5 * $ch;
                if ($width >= 40) {
                    if ($ch > 9) {
                        continue;
                    }
                    $blocks[] = ['channel' => $ch, 'members' => [$f, $f + 20], 'range' => [$f - 10, $f + 30]];
                } else {
                    $blocks[] = ['channel' => $ch, 'members' => [$f], 'range' => [$f - 10, $f + 10]];
                }
            }
        } elseif ($freq >= 5150 && $freq < 5925) {
            if ($width <= 20) {
                foreach (range(36, 177, 4) as $ch) {
                    $f = 5000 + 5 * $ch;
                    $blocks[] = ['channel' => $ch, 'members' => [$f], 'range' => [$f - 10, $f + 10]];
                }
            } else {
                $w = in_array($width, [40, 80, 160], true) ? $width : 80;
                foreach (self::CENTERS_5GHZ[$w] as $center) {
                    $members = [];
                    for ($ch = $center - intdiv($w, 10) + 2; $ch < $center + intdiv($w, 10); $ch += 4) {
                        $members[] = 5000 + 5 * $ch;
                    }
                    $c = 5000 + 5 * $center;
                    $blocks[] = [
                        'channel' => intdiv($members[0] - 5000, 5),
                        'members' => $members,
                        'range' => [$c - intdiv($w, 2), $c + intdiv($w, 2)],
                    ];
                }
            }
        }
        return $blocks;
    }

    /**
     * Returns the best channel for the access point: the block of the same
     * width that is far from the uplinks (up to FAR_MHZ), then the highest power.
     * Only blocks whose channels are all allowed count.
     *
     * @param array $ap an entry of parseIwDev()
     * @param array $uplinks entries of parseIwDev()
     * @param array $freqs the result of parseFrequencies() for the phy of the AP
     * @return array|null ["channel", "width", "dBm", "gap"], or null when no block is far enough
     */
    public static function suggest(array $ap, array $uplinks, array $freqs): ?array
    {
        $best = null;
        foreach (self::candidates($ap['freq'], $ap['width']) as $block) {
            $dbm = null;
            foreach ($block['members'] as $f) {
                if (!isset($freqs[$f])) {
                    continue 2;
                }
                $dbm = $dbm === null ? $freqs[$f] : min($dbm, $freqs[$f]);
            }
            $gap = PHP_INT_MAX;
            foreach ($uplinks as $up) {
                $gap = min($gap, self::gap([$block['range']], $up['ranges']));
            }
            if ($gap < self::CLOSE_MHZ) {
                continue;
            }
            // more than FAR_MHZ does not help: then the power counts, and
            // then the lowest channel (the most clients support it)
            $score = [min($gap, self::FAR_MHZ), $dbm, -$block['channel']];
            if ($best === null || $score > $best['score']) {
                $best = ['channel' => $block['channel'], 'width' => $ap['width'], 'dBm' => $dbm, 'gap' => $gap, 'score' => $score];
            }
        }
        if ($best !== null) {
            unset($best['score']);
        }
        return $best;
    }

    /**
     * Compares the access point with the wireless uplinks
     *
     * @param string $iwDev output of `iw dev`
     * @param callable $phyInfo function (string $phy): string, the output of `iw phy <phy> info`
     * @param string|null $apIface the hotspot interface of RaspAP, if known
     * @return array ['status' => none|ok|close|overlap, 'ap', 'uplink', 'gap', 'suggest']
     */
    public static function check(string $iwDev, callable $phyInfo, ?string $apIface = null): array
    {
        $interfaces = array_filter(self::parseIwDev($iwDev), function ($i) {
            return $i['channel'] !== null;
        });
        $aps = array_values(array_filter($interfaces, function ($i) {
            return $i['type'] === 'AP';
        }));
        $uplinks = array_values(array_filter($interfaces, function ($i) {
            return $i['type'] === 'managed';
        }));
        if ($apIface !== null) {
            usort($aps, function ($a, $b) use ($apIface) {
                return ($b['iface'] === $apIface) <=> ($a['iface'] === $apIface);
            });
        }
        if (!$aps || !$uplinks) {
            return ['status' => 'none'];
        }
        $ap = $aps[0];
        $worst = null;
        $gap = PHP_INT_MAX;
        foreach ($uplinks as $up) {
            $g = self::gap($ap['ranges'], $up['ranges']);
            if ($g < $gap) {
                $gap = $g;
                $worst = $up;
            }
        }
        $result = [
            'status' => $gap < 0 ? 'overlap' : ($gap < self::CLOSE_MHZ ? 'close' : 'ok'),
            'ap' => self::describe($ap),
            'uplink' => self::describe($worst),
            'gap' => max($gap, 0),
            'suggest' => null,
        ];
        if ($result['status'] !== 'ok' && preg_match('/^phy\d+$/', (string)$ap['phy'])) {
            $result['suggest'] = self::suggest($ap, $uplinks, self::parseFrequencies((string)$phyInfo($ap['phy'])));
        }
        return $result;
    }

    /**
     * Runs the check on this device
     *
     * @param string|null $apIface
     * @return array see check()
     */
    public static function run(?string $apIface = null): array
    {
        // www-data does not have /usr/sbin in its PATH
        $iw = is_executable('/usr/sbin/iw') ? '/usr/sbin/iw' : 'iw';
        $iwDev = (string)shell_exec($iw . ' dev 2>/dev/null');
        return self::check($iwDev, function (string $phy) use ($iw) {
            return (string)shell_exec($iw . ' phy ' . escapeshellarg($phy) . ' info 2>/dev/null');
        }, $apIface);
    }

    private static function describe(array $i): array
    {
        return [
            'iface' => $i['iface'],
            'channel' => $i['channel'],
            'width' => $i['widthLabel'],
            'ranges' => $i['ranges'],
        ];
    }
}
