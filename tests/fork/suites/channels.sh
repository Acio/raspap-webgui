#!/bin/bash
#
# Channel overlap warning: ChannelOverlap compares the frequencies of the
# hotspot with those of the wireless uplink, and suggests a channel far from
# the uplink. The endpoint gives the result to the web interface.

. /s/tests/fork/lib.sh

FX="$S/tests/fork/fixtures"
cat > /tmp/ov.php <<'P'
<?php
require '/s/src/RaspAP/Networking/ChannelOverlap.php';
$dev = file_get_contents($argv[1]);
$phy = file_get_contents($argv[2]);
echo json_encode(RaspAP\Networking\ChannelOverlap::check($dev, function ($p) use ($phy) { return $phy; }, $argv[3] ?? null));
P
# dev <AP channel line> <uplink channel line>: the Pi fixture with other channels
dev() {
    awk -v ap="$1" -v up="$2" '
        /Interface wlan1/ { i = "ap" } /Interface wlan0/ { i = "up" } /Unnamed/ { i = "" }
        /^\t\tchannel / { if (i == "ap") { print "\t\t" ap; next } if (i == "up") { if (up == "") next; print "\t\t" up; next } }
        { print }' "$FX/iw-dev-pi.txt" > /tmp/dev.txt
}
ov() { php /tmp/ov.php /tmp/dev.txt "$FX/iw-phy-rtl8912au.txt" "$@"; }
j() { jq -r "$1" <<< "$out"; }

echo "== the Pi now: hotspot ch 149/80, uplink ch 48/80"
cp "$FX/iw-dev-pi.txt" /tmp/dev.txt; out=$(ov wlan1)
c "status ok, 485 MHz apart, no suggestion" '[ "$(j .status)" = ok ] && [ "$(j .gap)" = 485 ] && [ "$(j .suggest)" = null ]'
c "the AP and the uplink are found by type" '[ "$(j .ap.iface)" = wlan1 ] && [ "$(j .uplink.iface)" = wlan0 ] && [ "$(j .ap.width)" = "80 MHz" ]'

echo "== same 80 MHz block (the slow case of 2026-11-08)"
dev "channel 36 (5180 MHz), width: 80 MHz, center1: 5210 MHz" "channel 48 (5240 MHz), width: 80 MHz, center1: 5210 MHz"; out=$(ov wlan1)
c "overlap" '[ "$(j .status)" = overlap ] && [ "$(j .gap)" = 0 ]'
c "suggestion: ch 149, 80 MHz, 13 dBm (52-144 have radar detection)" '[ "$(j .suggest.channel)" = 149 ] && [ "$(j .suggest.width)" = 80 ] && [ "$(j .suggest.dBm)" = 13 ]'

echo "== uplink on 149/80, hotspot on 149/80"
dev "channel 149 (5745 MHz), width: 80 MHz, center1: 5775 MHz" "channel 157 (5785 MHz), width: 80 MHz, center1: 5775 MHz"; out=$(ov)
c "overlap, suggestion ch 36 at 23 dBm" '[ "$(j .status)" = overlap ] && [ "$(j .suggest.channel)" = 36 ] && [ "$(j .suggest.dBm)" = 23 ]'

echo "== close, but no overlap"
dev "channel 36 (5180 MHz), width: 40 MHz, center1: 5190 MHz" "channel 48 (5240 MHz), width: 20 MHz, center1: 5240 MHz"; out=$(ov)
c "20 MHz apart: close" '[ "$(j .status)" = close ] && [ "$(j .gap)" = 20 ]'
c "suggestion keeps the width: a 40 MHz block far from ch 48, the lowest of the far blocks (149, not 165)" '[ "$(j .suggest.width)" = 40 ] && [ "$(j .suggest.channel)" = 149 ]'
dev "channel 36 (5180 MHz), width: 20 MHz, center1: 5180 MHz" "channel 44 (5220 MHz), width: 20 MHz, center1: 5220 MHz"; out=$(ov)
c "exactly 20 MHz between the edges of ch 36 and ch 44: close" '[ "$(j .status)" = close ] && [ "$(j .gap)" = 20 ]'

echo "== 2.4 GHz"
dev "channel 6 (2437 MHz), width: 20 MHz, center1: 2437 MHz" "channel 1 (2412 MHz), width: 20 MHz (no HT), center1: 2412 MHz"; out=$(ov)
c "ch 6 and ch 1 overlap (22 MHz wide signals, 5 MHz steps)" '[ "$(j .status)" = overlap ] || [ "$(j .status)" = close ]'
c "suggestion: ch 13, 40 MHz from ch 1" '[ "$(j .suggest.channel)" = 13 ] && [ "$(j .suggest.gap)" = 40 ]'
c "\"20 MHz (no HT)\" is parsed" '[ "$(j .uplink.width)" = "20 MHz" ]'
dev "channel 1 (2412 MHz), width: 20 MHz, center1: 2412 MHz" "channel 48 (5240 MHz), width: 80 MHz, center1: 5210 MHz"; out=$(ov)
c "hotspot 2.4 GHz, uplink 5 GHz: ok" '[ "$(j .status)" = ok ]'

echo "== 80+80 MHz"
dev "channel 36 (5180 MHz), width: 80+80 MHz, center1: 5210 MHz, center2: 5775 MHz" "channel 161 (5805 MHz), width: 20 MHz, center1: 5805 MHz"; out=$(ov)
c "the second segment counts: overlap with ch 161" '[ "$(j .status)" = overlap ] && [ "$(j .ap.width)" = "80+80 MHz" ] && [ "$(j ".ap.ranges | length")" = 2 ]'

echo "== nothing to compare"
dev "channel 149 (5745 MHz), width: 80 MHz, center1: 5775 MHz" ""; out=$(ov)
c "no wireless uplink (for example Ethernet): none" '[ "$(j .status)" = none ]'
sed 's/type AP/type managed/' "$FX/iw-dev-pi.txt" > /tmp/dev.txt; out=$(ov)
c "no access point: none" '[ "$(j .status)" = none ]'
printf '' > /tmp/dev.txt; out=$(ov)
c "no iw output: none" '[ "$(j .status)" = none ]'

echo "== frequencies of the phy"
out=$(php -r 'require "/s/src/RaspAP/Networking/ChannelOverlap.php"; echo json_encode(RaspAP\Networking\ChannelOverlap::parseFrequencies(file_get_contents($argv[1])));' "$FX/iw-phy-rtl8912au.txt")
c "radar, disabled and no-IR frequencies are not used" '[ "$(j ".\"5180\"")" = 23 ] && [ "$(j ".\"5260\"")" = null ] && [ "$(j ".\"2484\"")" = null ] && [ "$(j ".\"5745\"")" = 13 ]'

echo "== the endpoint"
setup_webroot
mkdir -p /etc/raspap; printf '[WifiInterface]\nWifiInterface = wlan1\n' > /etc/raspap/hostapd.ini
set_admin_password
# iw is replaced by a stub that prints the fixtures (overlap case)
dev "channel 36 (5180 MHz), width: 80 MHz, center1: 5210 MHz" "channel 48 (5240 MHz), width: 80 MHz, center1: 5210 MHz"
cp /tmp/dev.txt /opt/iw-dev.txt; cp "$FX/iw-phy-rtl8912au.txt" /opt/iw-phy.txt
printf '#!/bin/sh\ncase "$1" in dev) cat /opt/iw-dev.txt ;; phy) cat /opt/iw-phy.txt ;; esac\n' > /usr/sbin/iw; chmod 755 /usr/sbin/iw
SD=/tmp/ch-sess; mkdir -p $SD; chown www-data $SD
printf 'user_id|s:5:"admin";user_role|s:5:"admin";lastActivity|i:%d;csrf_token|s:64:"%s";' "$(date +%s)" "$(printf 'a%.0s' $(seq 64))" > $SD/sess_chtest
chown www-data $SD/sess_chtest; chmod 600 $SD/sess_chtest
sudo -u www-data php -d session.save_path=$SD -S 127.0.0.1:8098 -t "$W" > /tmp/phpch.log 2>&1 &
PHPS=$!
for i in $(seq 50); do curl -s -o /dev/null http://127.0.0.1:8098/ && break; sleep 0.1; done
U=http://127.0.0.1:8098/ajax/networking/get_channel_overlap.php
code=$(curl -s -o /dev/null -w '%{http_code}' -b PHPSESSID=chtest "$U")
c "GET is refused (405)" '[ "$code" = 405 ]'
code=$(curl -s -o /dev/null -w '%{http_code}' -b PHPSESSID=chtest -d csrf_token=wrong "$U")
c "POST with a wrong CSRF token is refused" '[ "$code" != 200 ]'
out=$(curl -s -b PHPSESSID=chtest -d csrf_token=$(printf 'a%.0s' $(seq 64)) "$U")
c "POST as admin: overlap, AP from hostapd.ini, suggestion ch 149" '[ "$(j .status)" = overlap ] && [ "$(j .ap.iface)" = wlan1 ] && [ "$(j .suggest.channel)" = 149 ]'
code=$(curl -s -o /dev/null -w '%{http_code}' -d csrf_token=x "$U")
c "no login: no result" '[ "$code" != 200 ]'
kill $PHPS 2>/dev/null

echo "== the web interface"
c "app.js loads the check on the dashboard, hotspot, client and networking pages" 'grep -q "initChannelOverlap_ajax" "$S/app/js/app.js" && grep -q "/hostapd_conf., ./wpa_conf., ./network_conf" "$S/app/js/app.js"'
c "the alert text is set with .text(), not as HTML" 'grep -q "append(\$(.<span></span>.).text(text))" "$S/app/js/ajax/channeloverlap.js"'

finish
