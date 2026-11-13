#!/bin/bash
#
# The small bugs of the reviews of RaspAP #2234, #2238 to #2241 (RaspAP #2243),
# as the fork fixes them: configport.sh, update_blocklist.sh, servicestart.sh,
# the sudo rules, OpenVPN names, the manual WireGuard config and clearlog.php.

. /s/tests/fork/lib.sh

setup_sudoers
stub_programs /bin/systemctl /sbin/reboot /sbin/ifup /usr/sbin/netplan /usr/local/sbin/onoff_huawei_hilink.sh \
    /usr/local/sbin/raspap-config-file.sh /usr/local/sbin/raspap-wifi.sh
al() { sudo -u www-data sudo -n -l "$@" > /dev/null 2>&1; }

echo "== sudo rules"
c "visudo accepts raspap.sudoers" 'visudo -cqf "$S/installers/raspap.sudoers"'
c "reboot without arguments allowed, with an argument refused" 'al /sbin/reboot && ! al /sbin/reboot --force'
c "rules without a caller removed: ifup, netplan, hilink, start of the activity monitor" '! al /sbin/ifup wlan0 && ! al /usr/sbin/netplan apply && ! al /usr/local/sbin/onoff_huawei_hilink.sh -c 1 && ! al /bin/systemctl start raspap-network-activity@wlan0.service'
c "stop of the activity monitor (hostapd.php) allowed" 'al /bin/systemctl stop "raspap-network-activity@*.service"'
c "the stop rule takes only the literal pattern, no other services" '! al /bin/systemctl stop "raspap-network-activity@a.service" ssh.service x.service && ! al /bin/systemctl stop raspap-network-activity@wlan0.service'
c "no sudo rule for visudo (it prints lines of any file)" '! al /usr/sbin/visudo -cf /etc/shadow && ! grep -q visudo "$S/installers/raspap.sudoers" && ! grep -q "sudo visudo" "$S/src/RaspAP/Plugins/PluginInstaller.php"'
c "dual mode: the hostapd file of an interface through the helper" 'al /usr/local/sbin/raspap-config-file.sh install hostapd wlan1'
c "wpa_cli reassociate and disconnect without an id through the helper" 'al /usr/local/sbin/raspap-wifi.sh wpa wlan0 reassociate && al /usr/local/sbin/raspap-wifi.sh wpa wlan0 disconnect'

echo "== configport.sh"
mkdir -p /etc/raspap/lighttpd /etc/lighttpd
install -m 750 "$S/installers/configport.sh" /etc/raspap/lighttpd/configport.sh
printf 'server.port                 = 80\n' > /etc/lighttpd/lighttpd.conf
pat=$'$serverBind = "\'\'";'
c "system.php passes an empty bind address as an empty argument" 'grep -qF "$pat" "$S/includes/system.php"'
(cd /tmp && bash -c "/etc/raspap/lighttpd/configport.sh '8081' '' /etc/lighttpd/lighttpd.conf raspap.local" > /dev/null 2>&1)
c "port and an empty bind address: port changes, no server.bind" 'grep -q "^server.port *= 8081" /etc/lighttpd/lighttpd.conf && ! grep -q server.bind /etc/lighttpd/lighttpd.conf'

# update_blocklist.sh: see the adblock suite (the script takes a list name)

echo "== servicestart.sh"
timeout 5 bash "$S/installers/servicestart.sh" --unknown > /dev/null 2>&1; rc=$?
c "unknown option: exit 2 at once (rc $rc)" '[ $rc = 2 ]'

echo "== OpenVPN names"
cat > /tmp/ovpn.php <<'EOF'
<?php
$src = file_get_contents('/s/includes/openvpn.php');
preg_match("/\\\$name = preg_replace\\('([^']+)', '_'/", $src, $m1);
preg_match("/preg_match\\('([^']+)', \\\$ovpncfg_id\\)/", file_get_contents('/s/ajax/openvpn/activate_ovpncfg.php'), $m2);
preg_match("/preg_match\\('([^']+)', \\\$ovpncfg_id\\)/", file_get_contents('/s/ajax/openvpn/del_ovpncfg.php'), $m3);
$ok = isset($m1[1], $m2[1], $m3[1]) && $m2[1] === $m3[1];
foreach (['My VPN (NL).ovpn', 'büro+1@x.ovpn', ' .-lead.ovpn', 'a;b$(c).ovpn', str_repeat('x', 150).'.ovpn'] as $f) {
    $name = substr(ltrim(preg_replace($m1[1], '_', pathinfo($f, PATHINFO_FILENAME)), ' .-'), 0, 100);
    $ok = $ok && preg_match($m2[1], $name) === 1 && strpos($name, '/') === false;
}
foreach (['../x', 'a/b', '.hidden', "a\nb", ''] as $bad) {
    $ok = $ok && preg_match($m2[1], $bad) !== 1;
}
echo $ok ? "PASS\n" : "FAIL\n";
EOF
c "upload names are accepted by both endpoints; ../, / and newline refused" '[ "$(php /tmp/ovpn.php)" = PASS ]'

echo "== manual WireGuard config"
cat > /tmp/wg.php <<'EOF'
<?php
function getDefaultNetValue($svc, $iface, $key) { $j = json_decode(file_get_contents('/s/config/defaults.json'), true); return $j[$svc][$iface][$key][0]; }
preg_match_all("/^\s*(\\\$config\[\] = 'Post(Up|Down) = '.*);\s*$/m", file_get_contents('/s/includes/wireguard.php'), $m);
$config = [];
foreach ($m[1] as $line) { eval($line.';'); }
echo implode("\n", $config), "\n";
EOF
out=$(php /tmp/wg.php)
c "PostUp gives ap, no %a" 'echo "$out" | grep -qx "PostUp = /etc/raspap/networking/wg-forward.sh up %i ap" && ! echo "$out" | grep -q "%a"'

echo "== clearlog.php as www-data, through the log helper"
install -o root -g root -m 755 "$S/installers/logs.sh" /usr/local/sbin/raspap-logs.sh
mkdir -p /tmp/cl
sed '/^require_once/d' "$S/ajax/logging/clearlog.php" > /tmp/cl/clearlog.php
cl() { sudo -u www-data php -r '$_POST["logfile"] = $argv[1]; include $argv[2];' -- "$1" /tmp/cl/clearlog.php; }
mkdir -p /var/log
for f in /tmp/hostapd.log /tmp/openvpn.log /var/log/dnsmasq.log /tmp/other.log; do echo data > $f; chmod 644 $f; done
cl /tmp/hostapd.log > /dev/null; cl /tmp/openvpn.log > /dev/null; cl /var/log/dnsmasq.log > /dev/null
c "the 3 logs are cleared" '[ ! -s /tmp/hostapd.log ] && [ ! -s /tmp/openvpn.log ] && [ ! -s /var/log/dnsmasq.log ]'
r4=$(cl /tmp/other.log); r5=$(cl /tmp/../tmp/other.log)
c "other log and a path with .. refused, file unchanged" '[ "$r4" = 1 ] && [ "$r5" = 1 ] && [ -s /tmp/other.log ]'


echo "== PHP warnings of the Pi log (2026-11-08)"
setup_webroot
mkdir -p /etc/raspap/networking
printf '{"dnsmasq":{"wlan0":{"dhcp-range":["10.3.141.50,10.3.141.254,255.255.255.0,12h"]}}}' > /etc/raspap/networking/defaults.json
out=$(cd "$W" && php -d error_reporting=E_ALL -d display_errors=stderr -r 'require "includes/config.php"; require "includes/defaults.php"; require "includes/functions.php";
    var_export(getDefaultNetValue("dnsmasq", "lo", "dhcp-range")); echo " "; echo getDefaultNetValue("dnsmasq", "wlan0", "dhcp-range");' 2>&1)
c "getDefaultNetValue: null for an interface without defaults (upstream 3.5.10), no warning" '[ "$out" = "NULL 10.3.141.50,10.3.141.254,255.255.255.0,12h" ]'
c "restapi.php sets \$docMsg also when the RestAPI does not run" 'grep -q "^    \$docMsg = .\{2\};" "$S/includes/restapi.php"'
c "index.php flushes the output buffer only when one is active" 'grep -q "if (ob_get_level() > 0) { ob_end_flush(); }" "$S/index.php"'

finish
