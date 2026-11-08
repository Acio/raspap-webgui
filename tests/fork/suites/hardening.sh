#!/bin/bash
#
# Small hardening changes of the fork: the RestAPI key helper, the mode of the
# hostapd configuration, root-owned units, the unit options, the pinned
# downloads, no unserialize() of /tmp files in the bundled Firewall plugin,
# and the web front end: security headers, the idle timeout on the server and
# an error page with details only for the admin user.

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

echo "== web front end"
SD=/tmp/fork-sess; mkdir -p $SD; chown www-data $SD; chmod 700 $SD
# the log directory, as the installer makes it
L=/var/log/raspap; rm -rf $L; install -d -o www-data -g www-data -m 750 $L
# a test page: "early" and "fatal" fail before the login check, "late" after it
cat > "$W/fork_page.php" <<'EOF'
<?php
require_once 'includes/config.php';
require_once 'includes/autoload.php';
$handler = new RaspAP\Exceptions\ExceptionHandler;
require_once 'includes/session.php';
if (isset($_GET['early'])) { throw new RuntimeException('secret <b>early</b>'); }
if (isset($_GET['fatal'])) { ini_set('memory_limit', '16M'); $a = str_repeat('x', 64 * 1024 * 1024); }
require_once 'includes/authenticate.php';
if (isset($_GET['late'])) { throw new RuntimeException('secret <b>late</b>'); }
echo 'page ok';
EOF
chown www-data "$W/fork_page.php"
sudo -u www-data php -d session.save_path=$SD -d display_errors=0 -S 127.0.0.1:8099 -t "$W" > /tmp/phps.log 2>&1 &
PHPS=$!
for i in $(seq 50); do curl -s -o /dev/null http://127.0.0.1:8099/fork_page.php && break; sleep 0.1; done
# sess <id> <age in seconds> [role]: a session file of a logged-in user
sess() {
    local role=""
    [ -n "${3:-}" ] && role="user_role|s:${#3}:\"$3\";"
    printf 'user_id|s:5:"admin";%slastActivity|i:%d;' "$role" $(($(date +%s) - $2)) > $SD/sess_$1
    chown www-data $SD/sess_$1; chmod 600 $SD/sess_$1
}
get() { curl -s -D /tmp/h.txt -o /tmp/b.txt -b "PHPSESSID=$1" "http://127.0.0.1:8099/$2"; }
hdr() { grep -qi "^$1" /tmp/h.txt; }

sess act1 10 admin; get act1 fork_page.php
c "a page: X-Frame-Options, CSP, nosniff, Referrer-Policy, no-store" 'grep -qx "page ok" /tmp/b.txt && hdr "X-Frame-Options: DENY" && hdr "Content-Security-Policy: frame-ancestors '"'"'none'"'"'; base-uri '"'"'self'"'"'; object-src '"'"'none'"'"'; form-action '"'"'self'"'"'" && hdr "X-Content-Type-Options: nosniff" && hdr "Referrer-Policy: same-origin" && hdr "Cache-Control: no-store"'
get act1 ajax/session/do_check_session.php
c "an ajax answer has the same headers" 'grep -q "\"status\":\"active\"" /tmp/b.txt && hdr "X-Frame-Options: DENY" && hdr "Cache-Control: no-store"'
c "all ajax files include session.php" '[ -z "$(grep -rL "includes/session.php" "$S/ajax" --include=*.php)" ]'

sess idle1 2000 admin; get idle1 fork_page.php
c "an idle session: the page goes to the login, the session ends" 'grep -q "^HTTP/1.1 302" /tmp/h.txt && hdr "Location: /login" && ! grep -q "page ok" /tmp/b.txt && ! grep -q user_id $SD/sess_idle1 2>/dev/null'
sess idle2 2000 admin; get idle2 ajax/session/do_check_session.php
c "an idle session: ajax gets 401 session_expired, the session ends" 'grep -q "^HTTP/1.1 401" /tmp/h.txt && grep -q "\"status\":\"session_expired\"" /tmp/b.txt && [ ! -s $SD/sess_idle2 ]'
sess act2 1300 admin; get act2 fork_page.php
c "a session below RASPI_SESSION_TIMEOUT stays" 'grep -qx "page ok" /tmp/b.txt'
c "session.js shows the expired window on 401" 'grep -q "jqXHR.status === 401" "$S/app/js/ajax/session.js"'

get none fork_page.php?early=1
ref=$(sed -n 's|.*<code>\([0-9a-f]\{8\}\)</code>.*|\1|p' /tmp/b.txt)
c "no login: a generic error page, no details, no X-Debug headers" 'grep -q "^HTTP/1.1 500" /tmp/h.txt && [ -n "$ref" ] && ! grep -q secret /tmp/b.txt && ! grep -qi "fork_page\|Stack trace" /tmp/b.txt && ! hdr X-Debug'
c "the error log has the reference and the message" 'grep -q "\[$ref\] secret <b>early</b> in .*fork_page.php" $L/error.log'
c "the error log is in /var/log/raspap, mode 640, not in /tmp" '[ "$(stat -c %U:%a $L/error.log)" = www-data:640 ] && [ ! -e /tmp/raspap_error.log ]'
sess lim1 10 limited; get lim1 fork_page.php?late=1
c "a limited user: a generic error page" 'grep -q "^HTTP/1.1 500" /tmp/h.txt && ! grep -q secret /tmp/b.txt && ! hdr X-Debug'
sess old1 10; get old1 fork_page.php?late=1
c "a session without a role: a generic error page" '! grep -q secret /tmp/b.txt'
sess adm1 10 admin; get adm1 fork_page.php?late=1
c "the admin user: details, escaped, no X-Debug headers" 'grep -q "secret &lt;b&gt;late&lt;/b&gt;" /tmp/b.txt && ! grep -q "<b>late" /tmp/b.txt && grep -q "Stack trace" /tmp/b.txt && grep -q "fork_page.php:9" /tmp/b.txt && ! hdr X-Debug'
get none fork_page.php?fatal=1
c "a fatal error: the generic error page and a log line" 'grep -q "<code>[0-9a-f]\{8\}</code>" /tmp/b.txt && ! grep -q "Allowed memory" /tmp/b.txt && grep -q "Allowed memory size" $L/error.log'
kill $PHPS 2>/dev/null

out=$(cd "$W" && sudo -u www-data php -d session.save_path=$SD -r 'require "includes/config.php"; require "includes/autoload.php"; session_start();
    $_SESSION["lastActivity"] = 1; $a = new \RaspAP\Auth\HTTPAuth;
    $r = ($a->login("admin", "wrong", "admin") ? "x" : "-") . ($a->isAdmin() ? "x" : "-");
    $r .= ($a->login("admin", "secret", "admin") ? "L" : "-") . ($a->isAdmin() ? "A" : "-") . ($a->isIdle() ? "I" : "-");
    echo $r;' 2>&1)
c "login() saves the admin role and resets the idle time" '[ "$out" = "--LA-" ]'


echo "== DHCP form (DnsmasqManager::validate)"
cat > /tmp/dv.php <<'P'
<?php
chdir('/var/www/html');
require 'includes/config.php'; require 'includes/autoload.php'; require 'includes/functions.php';
$base = ['static_leases' => ['mac' => ['aa:bb:cc:dd:ee:ff'], 'ip' => ['10.3.141.20'], 'comment' => ['nas']],
         'server' => ['9.9.9.9', '1.1.1.1#53', '/lan.example/192.168.1.1', '/ads.example/', '2606:4700:4700::1111'], 'DNS1' => '9.9.9.9', 'DNS2' => ''];
$case = json_decode($argv[1], true);
$post = array_replace_recursive($base, $case);
if (isset($case['__server'])) { $post['server'] = $case['__server']; }
echo count((new RaspAP\Networking\Hotspot\DnsmasqManager())->validate($post));
P
dv() { sudo -u www-data php /tmp/dv.php "$1" 2>&1; }
c "valid values: no errors" '[ "$(dv "{}")" = 0 ]'
for bad in '{"__server":["x\"><svg/onload=alert(1)>"]}' '{"__server":["9.9.9.9 log-queries"]}' '{"__server":["9.9.9.9\nlog-dhcp"]}' \
    '{"__server":["1.1.1.1#99999"]}' '{"__server":"9.9.9.9"}' '{"DNS1":"1.1.1.1,8.8.8.8"}' '{"DNS2":"evil"}' \
    '{"static_leases":{"mac":["aa:bb:cc:dd:ee:ff\nxyz"]}}' '{"static_leases":{"comment":["a\nserver=6.6.6.6"]}}' \
    '{"static_leases":{"comment":["xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"]}}' '{"static_leases":{"ip":["10.3.141.20,10.3.141.21"]}}'; do
    c "refused: $bad" '[ "$(dv "$bad")" -ge 1 ] 2>/dev/null'
done
c "the DHCP page escapes the upstream servers and the lease time" 'grep -q "value=\"<?php echo htmlspecialchars((string)\$server, ENT_QUOTES); ?>\"" "$S/templates/dhcp/advanced.php" && grep -q "htmlspecialchars(\$data\[.leaseTime.\]" "$S/templates/dhcp/summary.php"'
c "dhcp.php does not save dnsmasq after a failed dhcpcd check" 'awk "/function saveDHCPConfig/,/^}/" "$S/includes/dhcp.php" | grep -q "return false;"'


echo "== status messages (StatusMessage::addMessage)"
out=$(cd "$W" && php -r 'require "includes/autoload.php"; $s = new RaspAP\Messages\StatusMessage;
    $s->addMessage("<b>x</b> & \"q\""); $s->addMessage("<a href=\"/x\">link</a>", "warning", true, true);
    $s->addMessage("y", "warning alert-persistent"); $s->addMessage("z", "danger\" onclick=\"x"); echo implode("\n", $s->messages);' 2>&1)
c "text is escaped by default" 'echo "$out" | grep -q "&lt;b&gt;x&lt;/b&gt; &amp; &quot;q&quot;" && ! echo "$out" | grep -q "<b>x"'
c "HTML only with html=true" 'echo "$out" | grep -q "<a href=\"/x\">link</a>"'
c "the level keeps class names and loses quotes" 'echo "$out" | grep -q "alert-warning alert-persistent alert-dismissible" && echo "$out" | grep -q "alert-danger onclickx alert-dismissible"'
c "no caller escapes a message itself (it would show twice escaped)" '[ -z "$(cd "$S" && grep -rn --include="*.php" --exclude-dir=tests --exclude-dir=vendor "addMessage(" . | grep htmlspecialchars | grep -v ", true, true)")" ]'
c "HTML messages escape their values" '[ -z "$(cd "$S" && grep -rn --include="*.php" --exclude-dir=tests --exclude-dir=vendor "addMessage(" . | grep ", true, true)" | grep -v htmlspecialchars)" ]'

finish
