#!/bin/bash
#
# Small hardening changes of the fork: the RestAPI key helper, the mode of the
# hostapd configuration, root-owned units, the unit options, the pinned
# downloads, and no unserialize() of /tmp files in the bundled Firewall plugin.

. /s/tests/fork/lib.sh

echo "== RestAPI key helper (raspap-api-key.sh)"
setup_sudoers
mkdir -p /etc/raspap/api
install -o root -g root -m 755 "$S/installers/api-key.sh" /usr/local/sbin/raspap-api-key.sh
E=/etc/raspap/api/.env
printf 'OTHER=1\nRASPAP_API_KEY=oldkey123456\n' > $E; chown www-data $E; chmod 644 $E
k() { printf '%s\n' "$1" | sudo -u www-data sudo -n /usr/local/sbin/raspap-api-key.sh set 2>&1; }
out=$(k "newKey_123.~+/=-abc")
c "www-data sets a key through sudo" 'echo "$out" | grep -qx OK && grep -qx "RASPAP_API_KEY=newKey_123.~+/=-abc" $E'
c ".env is root:www-data 640, other lines kept, one key line" '[ "$(stat -c %U:%G:%a $E)" = root:www-data:640 ] && grep -qx OTHER=1 $E && [ "$(grep -c "^RASPAP_API_KEY=" $E)" = 1 ]'
for bad in "short" "a b c d e f g h" 'x;y;zzzzzzzzzz' "$(printf 'x%.0s' $(seq 1 130))" '$(id)abcdefgh'; do
    k "$bad" > /dev/null
    c "key refused: ${bad:0:20}" 'grep -qx "RASPAP_API_KEY=newKey_123.~+/=-abc" $E'
done
out=$(printf 'goodkey12345\nEVIL=1\n' | sudo -u www-data sudo -n /usr/local/sbin/raspap-api-key.sh set 2>&1)
c "only the first line is read" '! grep -q EVIL $E && grep -qx RASPAP_API_KEY=goodkey12345 $E'
c "other arguments refused by sudo" '! echo x | sudo -u www-data sudo -n /usr/local/sbin/raspap-api-key.sh set x > /dev/null 2>&1'
c "no sudo rule to move or touch .env" '! grep -qE "/tmp/.env|touch /etc/raspap/api/.env" "$S/installers/raspap.sudoers"'
setup_webroot
out=$(cd "$W" && sudo -u www-data php -r 'require "includes/config.php"; require "includes/autoload.php";
    $d = new \RaspAP\DotEnv\DotEnv("/etc/raspap/api/.env"); $d->load(); $d->set("RASPAP_API_KEY", "fromPHP_12345678");
    try { $d->set("OTHER", "x"); echo "no exception"; } catch (Exception $e) { echo "refused"; }' 2>&1)
c "DotEnv::set saves the key through the helper, other keys refused" '[ "$out" = refused ] && grep -qx RASPAP_API_KEY=fromPHP_12345678 $E'

echo "== hostapd configuration"
mkdir -p /etc/hostapd
install -o root -g root -m 755 "$S/installers/config-file.sh" /usr/local/sbin/raspap-config-file.sh
printf 'interface=wlan0\nssid=old\n' > /etc/hostapd/hostapd.conf; chmod 644 /etc/hostapd/hostapd.conf
printf 'interface=wlan0\nssid=new\nwpa_passphrase=secret123\n' | /usr/local/sbin/raspap-config-file.sh install hostapd > /dev/null 2>&1
c "hostapd.conf written as root:www-data 640" 'grep -q ssid=new /etc/hostapd/hostapd.conf && [ "$(stat -c %U:%G:%a /etc/hostapd/hostapd.conf)" = root:www-data:640 ]'
c "www-data can read it, other users can not" 'sudo -u www-data cat /etc/hostapd/hostapd.conf > /dev/null && ! sudo -u nobody cat /etc/hostapd/hostapd.conf > /dev/null 2>&1'
c "the installer installs hostapd.conf as root:www-data 640" 'grep -q "install -o root -g www-data -m 640 \$webroot_dir/config/hostapd.conf" "$S/installers/common.sh"'
c "the update sets the hostapd configurations to root:www-data 640" 'grep -q "chown root:www-data \"\$conf\" && sudo chmod 640 \"\$conf\"" "$S/installers/common.sh"'

echo "== units"
c "no unit is moved with mv (mv keeps the owner www-data)" '! grep -nE "mv [^|]*\.service" "$S/installers/common.sh"'
c "the update makes the RaspAP units root-owned" 'grep -q "sudo chown root:root \"\$unit\" && sudo chmod go-w \"\$unit\"" "$S/installers/common.sh"'
c "network monitor: not root (DynamicUser), old root files removed" 'grep -qx DynamicUser=yes "$S/installers/raspap-network-activity@.service" && ! grep -q "^User=root" "$S/installers/raspap-network-activity@.service" && grep -q "^ExecStartPre=+/bin/rm -f /dev/shm/net_activity" "$S/installers/raspap-network-activity@.service"'
c "restapi.service: NoNewPrivileges, no capabilities, ProtectSystem, PrivateTmp" 'for o in NoNewPrivileges=yes CapabilityBoundingSet= ProtectSystem=full PrivateTmp=yes; do grep -qx "$o" "$S/installers/restapi.service" || exit 1; done'

echo "== pinned downloads"
c "isoquery: SHA256 check before the install" 'grep -q "sha256sum -c --quiet" "$S/installers/common.sh" && grep -q d2f10836ef22134b0c648c6886d991cfda4baeb82b155f763e1afc01fff49adf "$S/installers/common.sh"'
c "mkcert: SHA256 check before the install" 'grep -q "sha256sum -c --quiet" "$S/installers/mkcert.sh" && grep -q 15f04f23b3c8fcb3ac00ba089d87bb507b5b2283d42fbe2123e2c74eaa672527 "$S/installers/mkcert.sh"'
printf 'data' > /tmp/f.bin
c "a wrong SHA256 stops sha256sum -c" '! echo "0000000000000000000000000000000000000000000000000000000000000000  /tmp/f.bin" | sha256sum -c --quiet - 2> /dev/null'

echo "== Firewall plugin"
c "no unserialize() in the bundled Firewall plugin" '! grep -q unserialize "$S/plugins-available/Firewall/Firewall.php"'

finish
