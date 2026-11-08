#!/bin/bash
#
# Plugins: install by name through plugin_helper.sh from the root-owned plugin
# list and bundled plugins, the checks of the helper, the migration of the old
# Firewall and NTP Server plugins, the NTP helper, and the helpers that the
# installer installs. Needs NET_ADMIN.

. /s/tests/fork/lib.sh

echo "== setup"
mkdir -p /etc/raspap/networking /etc/raspap/plugins /etc/iptables /etc/hostapd
setup_webroot
install -o root -g root -m 750 "$S/installers/plugin_helper.sh" /etc/raspap/plugins/plugin_helper.sh
install -o root -g root -m 755 "$S/installers/firewall.sh" /usr/local/sbin/raspap-firewall.sh
install -o root -g root -m 755 "$S/installers/ntp.sh" /usr/local/sbin/raspap-ntp.sh
install -o root -g root -m 755 "$S/installers/raspap-iptables-save.sh" /usr/local/sbin/raspap-iptables-save.sh
setup_sudoers
chown root:www-data /etc/raspap /etc/raspap/networking
chmod 1775 /etc/raspap /etc/raspap/networking
echo "interface=wlan1" > /etc/hostapd/hostapd.conf
H=/etc/raspap/plugins/plugin_helper.sh
P=/etc/raspap/plugins
ph() { sudo -u www-data sudo -n "$H" "$@" 2>&1; }

echo "== root-owned plugin list and bundled plugins (_install_plugin_sources)"
eval "$(sed -n '/^function _install_plugin_sources()/,/^}/p' "$S/installers/common.sh")"
ips() { ( sudo() { "$@"; }; _install_log() { :; }; _install_status() { echo "STATUS $*"; }; raspap_dir=/etc/raspap; webroot_dir=$W; _install_plugin_sources ); }
ips > /dev/null 2>&1
c "plugins.json and the bundled plugins are root-owned copies" 'cmp -s "$S/config/plugins.json" $P/plugins.json && [ "$(stat -c %U:%a $P/plugins.json)" = root:644 ] && [ -f $P/available/NTPServer/NTPServer.php ] && [ -z "$(find $P/available ! -user root -o -perm /022 ! -type l)" ]'
echo changed > $P/available/marker; ips > /dev/null 2>&1
c "a second run replaces the copy, no temporary directory left" '[ ! -e $P/available/marker ] && [ -z "$(ls -A $P | grep -E "^\.available|available\.old")" ]'
mv "$W/plugins-available" "$W/plugins-available.away"; echo x > "$W/plugins-available"
out=$(ips 2>&1)
rm -f "$W/plugins-available"; mv "$W/plugins-available.away" "$W/plugins-available"
c "a failed copy keeps the old copy" '[ -f $P/available/NTPServer/NTPServer.php ] && echo "$out" | grep -q "STATUS 1" && [ -z "$(ls -A $P | grep "^\.available")" ]'

echo "== the sudo rule of the helper"
c "www-data may run only: plugin_helper.sh install <name>" 'grep -qx "www-data ALL=(ALL) NOPASSWD:/etc/raspap/plugins/plugin_helper.sh install \*" /etc/sudoers.d/090_raspap && ! sudo -u www-data sudo -n -l $H sudoers /tmp/x > /dev/null 2>&1 && ! sudo -u www-data sudo -n -l $H config /tmp/x /etc/x > /dev/null 2>&1'
out=$(ph install Firewall extra); rc=$?
c "the helper takes exactly one name (rc $rc)" '[ $rc = 2 ] && echo "$out" | grep -q Usage'

echo "== install by name (PluginInstaller as www-data)"
pi() {
    (cd "$W" && sudo -u www-data php -r 'require "includes/config.php"; require "includes/autoload.php";
        try { var_export(\RaspAP\Plugins\PluginInstaller::getInstance()->installPluginByName($argv[1])); }
        catch (Exception $e) { echo "EXC: ".$e->getMessage(); }' -- "$1" 2>&1)
}
out=$(pi Firewall)
c "Firewall (bundled): $out" '[ "$out" = true ] && [ "$(readlink "$W/plugins/Firewall")" = "$W/plugins-available/Firewall" ] && [ "$(stat -c %U "$W/plugins/Firewall")" = www-data ] && grep -q "raspap-firewall.sh apply" /etc/sudoers.d/090_Firewall && [ "$(stat -c %U:%a /etc/sudoers.d/090_Firewall)" = root:440 ] && [ "$(stat -c %U:%a "$W/app/js/plugins/Firewall.js")" = www-data:644 ]'
out=$(pi Firewall)
c "a second install: already installed" 'echo "$out" | grep -q "already installed"'
# the test image has no apt lists: a stub records the package install
printf '#!/bin/sh\necho "apt-get $*" >> /tmp/apt.log\n' > /usr/local/sbin/apt-get; chmod 755 /usr/local/sbin/apt-get
out=$(pi "NTP Server")
rm -f /usr/local/sbin/apt-get
c "NTP Server (bundled, ntpsec from apt): $out" '[ "$out" = true ] && grep -q "install -y --no-install-recommends -- ntpsec" /tmp/apt.log && [ "$(readlink "$W/plugins/NTPServer")" = "$W/plugins-available/NTPServer" ] && [ "$(grep -c "raspap-ntp.sh" /etc/sudoers.d/090_NTPServer)" = 5 ] && [ -f "$W/app/js/plugins/NTPServer.js" ]'
for n in Wireshark "Captive portal" DynDNS "Tor Proxy" "Socks Proxy" "Tailscale VPN"; do
    out=$(pi "$n"); o2=$(ph install "$n"); rc=$?
    c "$n: not available, in PHP and in the helper (rc $rc)" 'echo "$out" | grep -q "not available in the hardened fork" && [ $rc = 2 ] && echo "$o2" | grep -q "not available" && [ -z "$(ls /etc/sudoers.d | grep -vE "^(090_raspap|090_Firewall|090_NTPServer|README)$")" ]'
done
out=$(pi "Unknown plugin")
c "a name that is not in the list is refused" 'echo "$out" | grep -q "not in the plugin list"'
o2=$(ph install "../../etc"); rc=$?
c "a path as name is refused by the helper (rc $rc)" '[ $rc = 2 ] && echo "$o2" | grep -q "not in the plugin list"'
c "PluginInstaller has no shell commands of its own, only the helper" '! grep -qE "shell_exec|[^_]exec\(|system\(|passthru|getPluginArchive|unzip" "$W/src/RaspAP/Plugins/PluginInstaller.php" && grep -q "\[.sudo., \$this->helperScriptPath, .install., \$name\]" "$W/src/RaspAP/Plugins/PluginInstaller.php"'
c "the plugins page shows the 6 plugins as not available" '(cd "$W" && php -r "require \"includes/config.php\"; require \"includes/autoload.php\"; \$p = RaspAP\\Plugins\\PluginInstaller::getInstance(); echo \$p->getHTMLPluginsTable(\$p->getUserPlugins());" 2>&1) | grep -c "disabled" | grep -qx 6'
c "plugins.js shows the install error as text, not as HTML" 'grep -q "readonly></textarea>.).val(String(errorMessage))" "$W/app/js/ajax/plugins.js" && ! grep -q "+ errorMessage +" "$W/app/js/ajax/plugins.js"'
c "do_plugin_install.php and plugins.js use only the name" 'grep -q plugin_name "$W/ajax/plugins/do_plugin_install.php" && ! grep -qE "plugin_uri|install_path|plugin_version" "$W/ajax/plugins/do_plugin_install.php" && ! grep -qE "plugin_uri|install_path" "$W/app/js/ajax/plugins.js"'

echo "== the checks of the helper (a test plugin)"
cp $P/plugins.json /tmp/plugins.json.real
mkdir -p $P/available/TestPlugin/conf $P/available/TestPlugin/js
echo conf > $P/available/TestPlugin/conf/a.conf; echo data > $P/available/TestPlugin/conf/d.json; echo js > $P/available/TestPlugin/js/t.js
ln -s /etc/shadow $P/available/TestPlugin/conf/link.conf; ln -s /etc $P/available/TestPlugin/etcdir
chown -R root:root $P/available/TestPlugin
mkdir -p /opt/ww && printf '#!/bin/sh\n' > /opt/ww/w.sh && chmod 777 /opt/ww/w.sh
# tp <jq change of the entry>: writes a plugin list with only the test plugin
base='{"name":"Test Plugin","version":"v1","install_path":"plugins-available","plugin_uri":"https://github.com/x/y/tree/z/plugins-available/TestPlugin","sudoers":["www-data ALL=(ALL) NOPASSWD:/bin/systemctl restart testplugin.service"],"dependencies":{},"configuration":[{"source":"conf/a.conf","destination":"/etc/testplugin/"},{"source":"conf/d.json","destination":"/var/www/html/plugins/TestPlugin-data/d.json"}],"permissions":[{"file":"/etc/testplugin/a.conf","owner":"root","group":"root","mode":"0640"}],"javascript":{"source":"js/t.js"}}'
tp() { jq -n --argjson e "$base" "{plugins: [\$e | $1]}" > $P/plugins.json; chmod 644 $P/plugins.json; }
clean() { rm -rf /etc/testplugin /etc/sudoers.d/090_TestPlugin "$W/plugins/TestPlugin" "$W/plugins/TestPlugin-data" "$W/app/js/plugins/t.js"; }
nothing() { [ ! -e /etc/sudoers.d/090_TestPlugin ] && [ ! -e /etc/testplugin ] && [ ! -L "$W/plugins/TestPlugin" ] && [ ! -e "$W/app/js/plugins/t.js" ] && [ -z "$(ls -A /etc/sudoers.d | grep "^\.plugin")" ]; }
for change in \
    '.sudoers = ["www-data ALL=(ALL) NOPASSWD:/bin/systemctl * testplugin.service"]' \
    '.sudoers = ["www-data ALL=(ALL) NOPASSWD:/bin/cp /tmp/x.conf /etc/x.conf"]' \
    '.sudoers = ["www-data ALL=(ALL) NOPASSWD:/bin/cat /var/tmp/x"]' \
    '.sudoers = ["www-data ALL=(ALL) NOPASSWD:/tmp/x.sh"]' \
    '.sudoers = ["www-data ALL=(ALL) NOPASSWD:/var/www/html/x.sh"]' \
    '.sudoers = ["www-data ALL=(ALL) NOPASSWD:/opt/ww/w.sh"]' \
    '.sudoers = ["root ALL=(ALL) NOPASSWD:/bin/true"]' \
    '.sudoers = ["www-data ALL=(ALL) NOPASSWD:ALL"]' \
    '.sudoers = ["www-data ALL=(ALL) NOPASSWD:/bin/true, /bin/bash"]' \
    '.sudoers = ["www-data ALL=(ALL) NOPASSWD:/usr/bin/tshark -i wlan0 -w x[1]"]' \
    '.configuration[0].destination = "/etc/sudoers.d/x"' \
    '.configuration[0].destination = "/etc/logrotate.d/x"' \
    '.configuration[0].destination = "/etc/ld.so.preload"' \
    '.configuration[0].destination = "/usr/local/sbin/raspap-x.sh"' \
    '.configuration[0].destination = "/etc/testplugin/../sudoers.d/y"' \
    '.configuration[0].destination = "etc/x.conf"' \
    '.configuration[0].source = "../../../../etc/shadow"' \
    '.configuration[0].source = "conf/link.conf"' \
    '.configuration[0].source = "etcdir/shadow"' \
    '.permissions[0].owner = "www-data"' \
    '.permissions[0].mode = "0666"' \
    '.permissions[0].file = "/etc/passwd"' \
    '.javascript = {"source": "conf/a.conf"}' \
    '.dependencies = {"./x.deb": "1"}' \
    '.keys = [{"key_url": "https://x/k.gpg"}]' \
    '.dpkgs = ["x.deb"]' \
    '.user_nonprivileged = {"name": "u", "pass": "p"}' \
    '.install_path = "plugins"' \
    '.plugin_uri = "https://github.com/x/y/tree/z/plugins-available/.."'; do
    clean; tp "$change"
    out=$(ph install "Test Plugin"); rc=$?
    c "refused, nothing changed: $change" '[ $rc = 2 ] && nothing'
done
clean; tp '.'
out=$(ph install "Test Plugin"); rc=$?
c "a good entry: rules root 440, config root, plugin data www-data, JavaScript, link (rc $rc)" '[ $rc = 0 ] && [ "$(stat -c %U:%a /etc/sudoers.d/090_TestPlugin)" = root:440 ] && [ "$(stat -c %U:%G:%a /etc/testplugin/a.conf)" = root:root:640 ] && [ "$(stat -c %U "$W/plugins/TestPlugin-data/d.json")" = www-data ] && [ "$(stat -c %U:%a "$W/app/js/plugins/t.js")" = www-data:644 ] && [ "$(readlink "$W/plugins/TestPlugin")" = "$W/plugins-available/TestPlugin" ]'
clean; echo file > /etc/testblock; tp '.configuration[0].destination = "/etc/testblock/a.conf" | .permissions = []'
out=$(ph install "Test Plugin"); rc=$?
c "a failed step removes the earlier changes (rc $rc)" '[ $rc != 0 ] && nothing && [ ! -e "$W/plugins/TestPlugin-data" -o -z "$(ls -A "$W/plugins/TestPlugin-data" 2>/dev/null)" ]'
rm -f /etc/testblock; clean
chown www-data $P/plugins.json; tp '.'; chown www-data $P/plugins.json
out=$(ph install "Test Plugin"); rc=$?
c "a plugin list that root does not own is refused (rc $rc)" '[ $rc = 1 ] && nothing'
cp /tmp/plugins.json.real $P/plugins.json; chown root:root $P/plugins.json; chmod 644 $P/plugins.json
rm -rf $P/available/TestPlugin

echo "== migration of the old Firewall plugin (common.sh)"
rm -rf "$W/plugins/Firewall" /etc/sudoers.d/090_Firewall "$W/app/js/plugins/Firewall.js"
mkdir -p "$W/plugins/Firewall"
cp "$S/tests/fork/fixtures/manifests/billz-Firewall.json" "$W/plugins/Firewall/manifest.json"
chown -R www-data "$W/plugins/Firewall"
printf 'www-data ALL=(ALL) NOPASSWD:/tmp/iptables_raspap.sh\n' > /etc/sudoers.d/090_Firewall
chmod 440 /etc/sudoers.d/090_Firewall
printf 'firewall-enable = 1\nssh-enable = \nhttp-enable = \nap-device = wlan1\n' > /etc/raspap/networking/firewall.conf
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo() { "$@"; }
_install_log() { :; }
_install_status() { [ "$1" = 0 ] || { echo "STATUS $*"; return 1; }; }
webroot_dir=$W
raspap_user=www-data
raspap_dir=/etc/raspap
eval "$(sed -n '/^function _migrate_to_bundled_plugin()/,/^}/p;/^function _migrate_firewall_plugin()/,/^}/p;/^function _migrate_ntpserver_plugin()/,/^}/p' "$S/installers/common.sh")"
out=$(_migrate_firewall_plugin 2>&1); rc=$?
c "migration ran through plugin_helper.sh (rc $rc)" '[ $rc = 0 ] && ! echo "$out" | grep -q STATUS'
c "plugins/Firewall is now the bundled plugin" '[ "$(readlink "$W/plugins/Firewall")" = "$W/plugins-available/Firewall" ]'
c "090_Firewall without /tmp rules, root 440" '! grep -q /tmp /etc/sudoers.d/090_Firewall && grep -q "raspap-firewall.sh apply" /etc/sudoers.d/090_Firewall && [ "$(stat -c %U:%a /etc/sudoers.d/090_Firewall)" = root:440 ]'
c "rules in the own chain, old flat rules gone" 'iptables -S RASPAP_FW_INPUT | grep -q -- "-i lo -j ACCEPT" && ! iptables -S INPUT | grep -q -- "-A INPUT -i lo" && ! iptables -S INPUT | grep -q -- "--state RELATED"'
out=$(_migrate_firewall_plugin 2>&1)
c "second run: nothing to do" '[ -z "$out" ]'

echo "== migration of the old NTP Server plugin (common.sh)"
rm -rf "$W/plugins/NTPServer" /etc/sudoers.d/090_NTPServer "$W/app/js/plugins/NTPServer.js"
mkdir -p "$W/plugins/NTPServer"
cp "$S/tests/fork/fixtures/manifests/billz-NTPServer.json" "$W/plugins/NTPServer/manifest.json"
chown -R www-data "$W/plugins/NTPServer"
manifest_sudoers "$S/tests/fork/fixtures/manifests/billz-NTPServer.json" > /etc/sudoers.d/090_NTPServer
chmod 440 /etc/sudoers.d/090_NTPServer
printf '#!/bin/sh\necho "apt-get $*" >> /tmp/apt.log\n' > /usr/local/sbin/apt-get; chmod 755 /usr/local/sbin/apt-get
out=$(_migrate_ntpserver_plugin 2>&1); rc=$?
rm -f /usr/local/sbin/apt-get
c "migration ran (rc $rc)" '[ $rc = 0 ]'
c "plugins/NTPServer is now the bundled plugin, NTPServer.js installed" '[ "$(readlink "$W/plugins/NTPServer")" = "$W/plugins-available/NTPServer" ] && [ -f "$W/app/js/plugins/NTPServer.js" ]'
c "090_NTPServer: only the helper, no /tmp and no wildcards, root 440" '! grep -qE "/tmp|\*|systemctl|ntpq" /etc/sudoers.d/090_NTPServer && [ "$(grep -c "raspap-ntp.sh" /etc/sudoers.d/090_NTPServer)" = 5 ] && [ "$(stat -c %U:%a /etc/sudoers.d/090_NTPServer)" = root:440 ]'
out=$(_migrate_ntpserver_plugin 2>&1)
c "second run: nothing to do" '[ -z "$out" ]'
unset -f sudo

echo "== NTP helper (raspap-ntp.sh)"
mkdir -p /etc/ntpsec
cp "$S/tests/fork/fixtures/ntp.conf-debian" /etc/ntpsec/ntp.conf
N=/usr/local/sbin/raspap-ntp.sh
nt() { printf '%s\n' "$1" | sudo -u www-data sudo -n $N install 2>&1; }
ok_conf() { cmp -s /etc/ntpsec/ntp.conf "$1" && [ "$(stat -c %U:%G:%a /etc/ntpsec/ntp.conf)" = root:root:644 ] && [ -z "$(ls -A /etc/ntpsec | grep "^\.")" ]; }
out=$(sudo -u www-data sudo -n $N install < "$S/tests/fork/fixtures/ntp.conf-pi" 2>&1)
c "the ntp.conf of the Pi is accepted, root:root 644" 'ok_conf "$S/tests/fork/fixtures/ntp.conf-pi"'
sed -E 's/^#(statsdir|statistics|filegen)/\1/' "$S/tests/fork/fixtures/ntp.conf-debian" > /tmp/ntp-stats.conf
out=$(sudo -u www-data sudo -n $N install < /tmp/ntp-stats.conf 2>&1)
c "the Debian default with statistics on is accepted" 'ok_conf /tmp/ntp-stats.conf'
cp /etc/ntpsec/ntp.conf /tmp/ntp.ref
for bad in 'includefile /etc/shadow' 'keys /etc/ntpsec/ntp.keys' 'logfile /etc/cron.d/x' 'driftfile /etc/x' \
    'driftfile /var/lib/ntpsec/../../../etc/x' 'statsdir /tmp/' 'filegen loopstats file ../x type day enable' \
    'refclock shm unit 0' 'server a.example iburst;touch' 'server $(id)' 'pool -x' 'setvar x = y' 'nts key /tmp/k'; do
    out=$(nt "server ok.example iburst
$bad")
    c "refused, ntp.conf unchanged: $bad" 'cmp -s /etc/ntpsec/ntp.conf /tmp/ntp.ref && echo "$out" | grep -q "line 2 is not allowed" && [ -z "$(ls -A /etc/ntpsec | grep "^\.")" ]'
done
out=$(head -c 70000 /dev/zero | tr '\0' '#' | sudo -u www-data sudo -n $N install 2>&1)
c "a configuration of more than 64 KB is refused" 'cmp -s /etc/ntpsec/ntp.conf /tmp/ntp.ref && echo "$out" | grep -q "too large"'
out=$(nt "# only a comment")
c "an empty configuration is refused" 'cmp -s /etc/ntpsec/ntp.conf /tmp/ntp.ref && echo "$out" | grep -q empty'
out=$(printf 'server x.example\n' | $N check 2>&1); rc=$?
c "check: accepted, nothing installed" '[ $rc = 0 ] && cmp -s /etc/ntpsec/ntp.conf /tmp/ntp.ref'
printf '#!/bin/sh\necho "systemctl $*"\n' > /usr/local/bin/systemctl; printf '#!/bin/sh\necho "ntpq $*"\n' > /usr/local/bin/ntpq
chmod 755 /usr/local/bin/systemctl /usr/local/bin/ntpq
out=$(sudo -u www-data sudo -n $N restart 2>&1; sudo -u www-data sudo -n $N peers 2>&1)
c "www-data: restart and peers run fixed commands" '[ "$out" = "systemctl restart ntpd.service
ntpq -p" ]'
c "other arguments are refused by sudo" '! sudo -u www-data sudo -n $N install /etc/passwd 2> /dev/null < /dev/null && ! sudo -u www-data sudo -n $N enable 2> /dev/null'
cp "$S/tests/fork/fixtures/ntp.conf-pi" /etc/ntpsec/ntp.conf
np() {
    (cd "$W" && sudo -u www-data php -r 'require "includes/config.php"; require "includes/autoload.php";
        require "plugins/NTPServer/NTPServer.php";
        $p = new RaspAP\Plugins\NTPServer\NTPServer("plugins", "NTPServer"); $s = new RaspAP\Messages\StatusMessage;
        $m = new ReflectionMethod($p, $argv[1]); $m->setAccessible(true);
        echo $m->invoke($p, $s, $argv[1] === "saveNTPSettings" ? explode(",", $argv[2]) : $argv[2]), "|", json_encode($s->messages ?? []);' -- "$@" 2>&1)
}
out=$(np saveNTPSettings "time.example iburst,1.2.3.4 iburst")
c "plugin: servers saved through the helper" 'grep -qx "server time.example iburst" /etc/ntpsec/ntp.conf && grep -qx "server 1.2.3.4 iburst" /etc/ntpsec/ntp.conf && ! grep -q "ntp.ubuntu.com" /etc/ntpsec/ntp.conf && [ ! -e /tmp/ntpdata ]'
cp /etc/ntpsec/ntp.conf /tmp/ntp.ref
out=$(np saveNTPSettings 'x.example" onmouseover="alert(1)')
c "plugin: a server value with quotes is refused, the message is escaped" 'cmp -s /etc/ntpsec/ntp.conf /tmp/ntp.ref && echo "$out" | grep -q "&quot;" && ! echo "$out" | grep -q "\" onmouseover"'
mv /etc/ntpsec/ntp.conf /etc/ntpsec/ntp.conf.away
out=$(np saveNTPSettings "time.example iburst")
c "plugin: no ntp.conf gives 1 (not false, which == 0 and restarted ntpd)" '[ "${out%%|*}" = 1 ] && echo "$out" | grep -q "not found"'
mv /etc/ntpsec/ntp.conf.away /etc/ntpsec/ntp.conf
c "plugin: the callers compare the result with === 0" '[ "$(grep -c "if (\$return === 0)" "$S/plugins-available/NTPServer/NTPServer.php")" = 2 ] && ! grep -q "\$return == 0" "$S/plugins-available/NTPServer/NTPServer.php"'
c "the bundled plugin has no /tmp files, no unserialize and no direct sudo commands" '! grep -vE "^\s*(\*|//)" "$S/plugins-available/NTPServer/NTPServer.php" | grep -qE "/tmp/|unserialize|sudo /bin|sudo /usr/bin"'

echo "== installer: helpers of the plugins"
systemctl() { :; }
rm -f /usr/local/sbin/raspap-firewall.sh /usr/local/sbin/raspap-ntp.sh
sudo() { "$@"; }
raspap_dir=/etc/raspap
# from the comment of the plugin helpers to the end of the Tailscale block
eval "f() { $(awk '/# The root helpers of the Firewall and NTP Server plugins, and the files of the Tailscale/ {p = 1} p {print} p && /tailscale-ethtool@.service/ {t = 1} t && /^    fi$/ {exit}' "$S/installers/common.sh") ; }"
f
unset -f sudo systemctl
c "firewall and NTP helpers, ts-optimize and the tailscale unit installed as root" '[ "$(stat -c %U:%a /usr/local/sbin/raspap-firewall.sh)" = root:755 ] && [ "$(stat -c %U:%a /usr/local/sbin/raspap-ntp.sh)" = root:755 ] && [ "$(stat -c %U:%a /usr/local/sbin/raspap-ts-optimize.sh)" = root:755 ] && [ "$(stat -c %U:%a /etc/systemd/system/tailscale-ethtool@.service)" = root:644 ]'
c "the update does not run submodule update --remote" '! grep -q "submodule update --remote" "$S/installers/common.sh"'

finish
