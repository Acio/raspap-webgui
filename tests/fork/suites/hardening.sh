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
set_admin_password
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
c "a page: X-Frame-Options, CSP, nosniff, Referrer-Policy, no-store" 'grep -qx "page ok" /tmp/b.txt && hdr "X-Frame-Options: DENY" && hdr "Content-Security-Policy: frame-ancestors '"'"'none'"'"'; base-uri '"'"'self'"'"'; object-src '"'"'none'"'"'; form-action '"'"'self'"'"'" && hdr "X-Content-Type-Options: nosniff" && hdr "Referrer-Policy: same-origin" && hdr "Cache-Control: no-store" && hdr "Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), usb=()"'
get act1 ajax/session/do_check_session.php
c "an ajax answer has the same headers" 'grep -q "\"status\":\"active\"" /tmp/b.txt && hdr "X-Frame-Options: DENY" && hdr "Cache-Control: no-store"'
c "all ajax files include session.php" '[ -z "$(grep -rL "includes/session.php" "$S/ajax" --include=*.php)" ]'

sess idle1 2000 admin; get idle1 fork_page.php
c "an idle session: the page goes to the login, the session ends" 'grep -q "^HTTP/1.1 302" /tmp/h.txt && hdr "Location: /login" && ! grep -q "page ok" /tmp/b.txt && ! grep -q user_id $SD/sess_idle1 2>/dev/null'
sess idle2 2000 admin; get idle2 ajax/session/do_check_session.php
c "an idle session: ajax gets 401 session_expired, the session ends" 'grep -q "^HTTP/1.1 401" /tmp/h.txt && grep -q "\"status\":\"session_expired\"" /tmp/b.txt && [ ! -s $SD/sess_idle2 ]'
sess act2 1300 admin; get act2 fork_page.php
c "a session below RASPI_SESSION_TIMEOUT stays" 'grep -qx "page ok" /tmp/b.txt'
curl -s -D /tmp/h.txt -o /dev/null -b "PHPSESSID=chosenbyanother0000000000000001" "http://127.0.0.1:8099/fork_page.php"
c "strict mode: an unknown session id is not used, PHP makes a new one" 'grep -qi "^Set-Cookie: PHPSESSID=" /tmp/h.txt && ! grep -qi "^Set-Cookie: PHPSESSID=chosenbyanother" /tmp/h.txt && [ ! -e $SD/sess_chosenbyanother0000000000000001 ]'
# old <id> <login age> <idle seconds>: a session with a login time
old() { printf 'user_id|s:5:"admin";user_role|s:5:"admin";loginTime|i:%d;lastActivity|i:%d;' $(($(date +%s) - $2)) $(($(date +%s) - $3)) > $SD/sess_$1; chown www-data $SD/sess_$1; chmod 600 $SD/sess_$1; }
old age1 30000 10; get age1 fork_page.php
c "absolute timeout: a login of more than 8 hours goes to the login, also when active" 'grep -q "^HTTP/1.1 302" /tmp/h.txt && hdr "Location: /login" && ! grep -q user_id $SD/sess_age1 2>/dev/null'
old age2 30000 10; get age2 ajax/session/do_check_session.php
c "absolute timeout: ajax gets 401 session_expired" 'grep -q "^HTTP/1.1 401" /tmp/h.txt'
old age3 3600 10; get age3 fork_page.php
c "a login of 1 hour stays" 'grep -qx "page ok" /tmp/b.txt'
sess nolt 10 admin; get nolt fork_page.php
c "a session without a login time stays, and gets one" 'grep -qx "page ok" /tmp/b.txt && grep -q "loginTime|i:" $SD/sess_nolt'
# upstream 3.5.10: with the default password, an admin must change it first
mv /etc/raspap/raspap.auth /tmp/raspap.auth.keep
sess dflt 10 admin; get dflt fork_page.php
c "default password: a page is refused (403) until the change" 'grep -q "^HTTP/1.1 403" /tmp/h.txt && grep -q "Password change required" /tmp/b.txt && ! grep -q "page ok" /tmp/b.txt'
get dflt ajax/session/do_check_session.php
c "default password: the session check still answers, the session stays" 'grep -q "\"status\":\"active\"" /tmp/b.txt && grep -q "user_id" $SD/sess_dflt'
mv /tmp/raspap.auth.keep /etc/raspap/raspap.auth
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
    $r .= ($a->login("admin", "fork-test-password", "admin") ? "L" : "-") . ($a->isAdmin() ? "A" : "-") . ($a->isIdle() ? "I" : "-");
    echo $r;' 2>&1)
c "login() saves the admin role and resets the idle time" '[ "$out" = "--LA-" ]'
out=$(cd "$W" && sudo -u www-data php -d session.save_path=$SD -r 'require "includes/config.php"; require "includes/autoload.php"; session_start();
    $a = new \RaspAP\Auth\HTTPAuth; $a->login("admin", "fork-test-password", "admin"); echo (time() - $_SESSION["loginTime"] < 5 ? "T" : "-"), ($a->isTooOld() ? "O" : "-");' 2>&1)
c "login() saves the login time" '[ "$out" = "T-" ]'


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


echo "== PHP 8.2+ deprecations in the error page"
out=$(cd "$W" && php -d error_reporting=E_ALL -d display_errors=stderr -r 'require "includes/autoload.php"; new RaspAP\Exceptions\HtmlErrorRenderer(); echo "ok";' 2>&1)
c "HtmlErrorRenderer has no dynamic properties" '[ "$out" = ok ]'


echo "== reset of the hotspot (HotspotReset, do_sys_reset.php)"
FX="$S/tests/fork/fixtures"
hr() { local code="$1"; shift; (cd "$W" && php -r 'require "includes/autoload.php"; use RaspAP\Networking\Hotspot\HotspotReset as R; $d = json_decode(file_get_contents("config/defaults.json"), true);'"$code" -- "$@" 2>&1); }
c "the hotspot interface comes from hostapd.ini, else wlan0" '[ "$(hr "echo R::apInterface([\"WifiInterface\" => \"wlan1\"]), R::apInterface([\"WifiInterface\" => \"wl;an\"]), R::apInterface(false);")" = wlan1wlan0wlan0 ]'
out=$(hr 'echo R::hostapd(file_get_contents("config/hostapd.conf"), "wlan1", "interface=wlan1\ncountry_code=NL\n");')
c "hostapd.conf: the hotspot interface, the country code stays, the rest is default" 'echo "$out" | grep -qx interface=wlan1 && echo "$out" | grep -qx country_code=NL && echo "$out" | grep -qx ssid=RaspAP && ! echo "$out" | grep -qx interface=wlan0'
out=$(hr 'echo R::hostapd(file_get_contents("config/hostapd.conf"), "wlan1", "country_code=;x\n");')
c "hostapd.conf: an invalid country code gives the default" 'echo "$out" | grep -qx country_code=GB'
out=$(hr '$n = R::defaults($d, "wlan1"); echo R::dhcpcd(file_get_contents($argv[1]), file_get_contents("config/dhcpcd.conf"), "wlan1", $n["dhcp"]);' "$FX/dhcpcd.conf-pi")
c "dhcpcd.conf: the wlan0 uplink blocks stay, the wlan1 block once, with its defaults" '[ "$(echo "$out" | grep -c "^interface wlan0")" = 2 ] && [ "$(echo "$out" | grep -c "^interface wlan1")" = 1 ] && echo "$out" | grep -qx "static ip_address=10.9.141.1/24" && echo "$out" | grep -qx "hostname" && [ "$(echo "$out" | grep -c "^nogateway")" = 3 ]'
out=$(hr '$n = R::defaults($d, "wlan1"); echo R::dhcpcd(null, file_get_contents("config/dhcpcd.conf"), "wlan1", $n["dhcp"]);')
c "dhcpcd.conf without a current file: the default global part and the wlan1 block, no wlan0 block" '! echo "$out" | grep -q "^interface wlan0" && echo "$out" | grep -qx "interface wlan1" && echo "$out" | grep -qx "clientid"'
out=$(hr '$n = R::defaults($d, "wlan1"); echo R::dnsmasq(file_get_contents("config/090_wlan0.conf"), "wlan1", $n["range"]);')
c "dnsmasq: interface wlan1 with its range" 'echo "$out" | grep -qx interface=wlan1 && echo "$out" | grep -qx "dhcp-range=10.9.141.50,10.9.141.254,255.255.255.0,12h" && ! echo "$out" | grep -q wlan0'
c "an interface without defaults gets the defaults of wlan0" '[ "$(hr "\$n = R::defaults(\$d, \"wlx001122\"); echo \$n[\"dhcp\"][\"static ip_address\"], \" \", \$n[\"range\"];")" = "10.3.141.1 10.3.141.50,10.3.141.254,255.255.255.0,12h" ]'

# end to end: the config file helper as root, the endpoint as www-data
install -o root -g root -m 755 "$S/installers/config-file.sh" /usr/local/sbin/raspap-config-file.sh
mkdir -p /etc/raspap/networking /etc/raspap/backups /etc/dnsmasq.d /etc/hostapd
chown www-data /etc/raspap/backups
cp "$W/config/defaults.json" /etc/raspap/networking/defaults.json
printf 'WifiInterface = wlan1\n' > /etc/raspap/hostapd.ini
printf 'interface=wlan1\nssid=Mine\nwpa_passphrase=mysecret123\nchannel=149\nhw_mode=a\ncountry_code=NL\n' > /etc/hostapd/hostapd.conf
cp "$FX/dhcpcd.conf-pi" /etc/dhcpcd.conf
printf 'interface=wlan1\ndhcp-range=10.9.141.60,10.9.141.70,255.255.255.0,1h\n' > /etc/dnsmasq.d/090_wlan1.conf
printf 'log-facility=/var/log/dnsmasq.log\nconf-dir=/etc/dnsmasq.d\nlog-queries\n' > /etc/dnsmasq.d/090_raspap.conf
printf 'interface=wlan0\n' > /etc/dnsmasq.d/090_eth0.conf
for f in /etc/hostapd/hostapd.conf /etc/dhcpcd.conf /etc/dnsmasq.d/090_wlan1.conf /etc/dnsmasq.d/090_raspap.conf /etc/dnsmasq.d/090_eth0.conf; do cp $f /tmp/ref.$(basename $f); done
TOK=$(printf 'b%.0s' $(seq 64))
printf 'user_id|s:5:"admin";user_role|s:5:"admin";lastActivity|i:%d;loginTime|i:%d;csrf_token|s:64:"%s";' "$(date +%s)" "$(date +%s)" "$TOK" > $SD/sess_resettest
chown www-data $SD/sess_resettest; chmod 600 $SD/sess_resettest
sudo -u www-data php -d session.save_path=$SD -S 127.0.0.1:8097 -t "$W" > /tmp/phpreset.log 2>&1 &
PHPR=$!
for i in $(seq 50); do curl -s -o /dev/null http://127.0.0.1:8097/ && break; sleep 0.1; done
R=http://127.0.0.1:8097/ajax/networking/do_sys_reset.php
cp "$S/installers/config-file.sh" /tmp/cf.real
printf '#!/bin/bash\n[ "$2 $3" = "dnsmasq raspap" ] && { echo "refused for the test" >&2; exit 1; }\nexec /tmp/cf.real "$@"\n' > /usr/local/sbin/raspap-config-file.sh
out=$(curl -s -b PHPSESSID=resettest -d csrf_token=$TOK "$R")
c "a failed step: an error, and all files are the old files again" 'echo "$out" | grep -q "\"return\":1" && echo "$out" | grep -q "old configuration stays" && for f in hostapd.conf dhcpcd.conf 090_wlan1.conf 090_raspap.conf; do d=/etc/dnsmasq.d/$f; [ $f = hostapd.conf ] && d=/etc/hostapd/$f; [ $f = dhcpcd.conf ] && d=/etc/$f; cmp -s $d /tmp/ref.$f || exit 1; done'
install -o root -g root -m 755 "$S/installers/config-file.sh" /usr/local/sbin/raspap-config-file.sh
out=$(curl -s -b PHPSESSID=resettest -d csrf_token=$TOK "$R")
c "reset: done for wlan1" 'echo "$out" | grep -q "\"return\":0" && echo "$out" | grep -q "on wlan1"'
c "reset: hostapd.conf default on wlan1, country NL stays, own SSID and passphrase gone" 'grep -qx interface=wlan1 /etc/hostapd/hostapd.conf && grep -qx country_code=NL /etc/hostapd/hostapd.conf && grep -qx ssid=RaspAP /etc/hostapd/hostapd.conf && ! grep -q mysecret123 /etc/hostapd/hostapd.conf'
c "reset: dhcpcd.conf keeps the wlan0 uplink blocks, wlan1 gets its defaults" '[ "$(grep -c "^interface wlan0" /etc/dhcpcd.conf)" = 2 ] && [ "$(grep -c "^interface wlan1" /etc/dhcpcd.conf)" = 1 ] && grep -qx "static ip_address=10.9.141.1/24" /etc/dhcpcd.conf'
c "reset: dnsmasq of wlan1 default, 090_raspap default, other dnsmasq files stay, no 090_wlan0" 'grep -qx "dhcp-range=10.9.141.50,10.9.141.254,255.255.255.0,12h" /etc/dnsmasq.d/090_wlan1.conf && ! grep -q log-queries /etc/dnsmasq.d/090_raspap.conf && cmp -s /etc/dnsmasq.d/090_eth0.conf /tmp/ref.090_eth0.conf && [ ! -e /etc/dnsmasq.d/090_wlan0.conf ]'
b=$(ls -d /etc/raspap/backups/reset-* | tail -1)
c "reset: the old files are saved, directory 700, files 600, also the old passphrase" '[ "$(stat -c %U:%a "$b")" = www-data:700 ] && [ -z "$(find "$b" -type f ! -perm 600)" ] && cmp -s "$b/hostapd.conf" /tmp/ref.hostapd.conf && cmp -s "$b/dhcpcd.conf" /tmp/ref.dhcpcd.conf'
n=0; for i in 1 2 3; do curl -s -b PHPSESSID=resettest -d csrf_token=$TOK "$R" | grep -q "\"return\":0" && n=$((n + 1)); done
c "three resets in the same second: each one works" '[ $n = 3 ]'
c "reset: only the 3 newest saves stay" '[ "$(ls -d /etc/raspap/backups/reset-* | wc -l)" = 3 ]'
c "reset: GET is refused, and no login gives no reset" '[ "$(curl -s -o /dev/null -w %{http_code} -b PHPSESSID=resettest "$R")" != 200 ] && ! curl -s -d csrf_token=x "$R" | grep -q "\"return\":0"'
kill $PHPR 2>/dev/null

finish
