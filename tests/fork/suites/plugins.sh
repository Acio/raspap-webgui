#!/bin/bash
#
# Plugins: the guards of plugin_helper.sh, install by name from the plugin list
# (bundled and downloaded), the migration of the old Firewall plugin, and the
# helpers that the installer installs. Needs NET_ADMIN and internet access
# (one plugin download from GitHub).

. /s/tests/fork/lib.sh

echo "== setup"
mkdir -p /etc/raspap/networking /etc/raspap/plugins /etc/iptables /etc/hostapd
setup_webroot
install -o root -g root -m 750 "$S/installers/plugin_helper.sh" /etc/raspap/plugins/plugin_helper.sh
install -o root -g root -m 755 "$S/installers/firewall.sh" /usr/local/sbin/raspap-firewall.sh
install -o root -g root -m 755 "$S/installers/raspap-iptables-save.sh" /usr/local/sbin/raspap-iptables-save.sh
setup_sudoers
chown root:www-data /etc/raspap /etc/raspap/networking
chmod 1775 /etc/raspap /etc/raspap/networking
echo "interface=wlan1" > /etc/hostapd/hostapd.conf
H=/etc/raspap/plugins/plugin_helper.sh
ph() { sudo -u www-data sudo -n "$H" "$@" 2>&1; }
sud() { printf '%s\n' "$2" > "/tmp/$1"; chown www-data "/tmp/$1"; ph sudoers "/tmp/$1"; }

echo "== plugin_helper.sh: sudo rules"
out=$(sud 090_Good "www-data ALL=(ALL) NOPASSWD:/bin/systemctl * danted.service
www-data ALL=(ALL) NOPASSWD:/bin/cp /tmp/danted.conf /etc/danted.conf")
c "good rules installed, root 440" 'echo "$out" | grep -q OK && [ "$(stat -c %U:%a /etc/sudoers.d/090_Good)" = root:440 ]'
sud 090_Fw "www-data ALL=(ALL) NOPASSWD:/tmp/iptables_raspap.sh" > /dev/null
c "rule for a /tmp script refused" '[ ! -e /etc/sudoers.d/090_Fw ]'
sud 090_Web "www-data ALL=(ALL) NOPASSWD:/var/www/html/x.sh" > /dev/null
c "rule for a web root script refused" '[ ! -e /etc/sudoers.d/090_Web ]'
sud 090_Root "root ALL=(ALL) NOPASSWD:/bin/true" > /dev/null
c "rule for another user refused" '[ ! -e /etc/sudoers.d/090_Root ]'
sud 090_All "www-data ALL=(ALL) NOPASSWD:ALL" > /dev/null
c "NOPASSWD:ALL refused" '[ ! -e /etc/sudoers.d/090_All ]'
cp /etc/sudoers.d/090_raspap /tmp/raspap.ref
sud 090_raspap "www-data ALL=(ALL) NOPASSWD:/bin/true" > /dev/null
c "090_raspap can not be replaced" 'cmp -s /etc/sudoers.d/090_raspap /tmp/raspap.ref'
sud 090_Bad "www-data ALL=(ALL) NOPASSWD:/bin/true ,,," > /dev/null
c "invalid syntax refused" '[ ! -e /etc/sudoers.d/090_Bad ]'
mkdir -p /opt/x && printf '#!/bin/sh\n' > /opt/x/w.sh && chmod 777 /opt/x/w.sh
sud 090_Ww "www-data ALL=(ALL) NOPASSWD:/opt/x/w.sh" > /dev/null
c "world-writable command refused" '[ ! -e /etc/sudoers.d/090_Ww ]'
out=$(ph sudoers /etc/hostname)
c "sudoers file outside /tmp refused" '! echo "$out" | grep -qx OK'

echo "== plugin_helper.sh: config, permissions, javascript, plugin"
echo src > /tmp/src.conf; chown www-data /tmp/src.conf
for d in /usr/local/sbin/raspap-x.sh /etc/sudoers.d/x /etc/raspap/networking/x.json /etc/systemd/system/x.service \
    /etc/danted/../sudoers.d/y /var/www/html/includes/x.php /etc/iptables/rules.v4; do
    out=$(ph config /tmp/src.conf "$d")
    c "config to $d refused" '! echo "$out" | grep -qx OK && ! grep -qx src "$(realpath -m "$d")" 2> /dev/null'
done
out=$(ph config /tmp/src.conf /etc/danted.conf)
c "config to /etc/danted.conf: root:root 644" 'echo "$out" | grep -qx OK && [ "$(stat -c %U:%G:%a /etc/danted.conf)" = root:root:644 ]'
out=$(ph config /tmp/src.conf /etc/nodogsplash/htdocs/)
c "config into a directory: file root-owned, directory not chowned" 'echo "$out" | grep -qx OK && [ "$(stat -c %U /etc/nodogsplash/htdocs/src.conf)" = root ] && [ "$(stat -c %U /etc/nodogsplash/htdocs)" = root ]'
out=$(ph config /tmp/src.conf "$W/plugins/X/data.json")
c "config into the plugin data: www-data" 'echo "$out" | grep -qx OK && [ "$(stat -c %U "$W/plugins/X/data.json")" = www-data ]'
rm -rf "$W/plugins/X"
ln -s /etc/hostname /etc/linkdest
out=$(ph config /tmp/src.conf /etc/linkdest)
c "config to a symlink refused" '! echo "$out" | grep -qx OK && [ "$(cat /etc/hostname)" != src ]'
ph permissions /usr/local/sbin/raspap-firewall.sh www-data www-data 0777 > /dev/null
c "permissions on a helper refused" '[ "$(stat -c %U:%a /usr/local/sbin/raspap-firewall.sh)" = root:755 ]'
ph permissions /etc/danted.conf root root 0640 > /dev/null
c "permissions on a plugin file allowed" '[ "$(stat -c %a /etc/danted.conf)" = 640 ]'
ph permissions /etc/danted.conf root root "u+s,a+w" > /dev/null
c "invalid mode refused" '[ "$(stat -c %a /etc/danted.conf)" = 640 ]'
echo x > /tmp/x.js; chown www-data /tmp/x.js
ph javascript /tmp/x.js /etc/raspap/ > /dev/null
c "JavaScript outside app/js/plugins refused" '[ ! -e /etc/raspap/x.js ]'
ph plugin /tmp /etc/raspap/plugins/Evil > /dev/null
c "plugin copy outside plugins/ refused" '[ ! -e /etc/raspap/plugins/Evil ]'

echo "== the sudo rules of the plugins in the list"
for f in "$S"/tests/fork/fixtures/manifests/billz-*.json "$S"/plugins-available/*/manifest.json; do
    n=$(basename "$(dirname "$f")")
    [ "$n" = manifests ] && n=$(basename "$f" .json)
    n=${n//-/}
    manifest_sudoers "$f" > "/tmp/090_$n"; chown www-data "/tmp/090_$n"
    r=$(ph sudoers "/tmp/090_$n")
    if [ "$n" = billzFirewall ]; then
        c "old billz Firewall rules refused" '! echo "$r" | grep -qx OK'
    else
        c "rules of $n accepted" 'echo "$r" | grep -qx OK'
    fi
done
find /etc/sudoers.d -name '090_*' ! -name 090_raspap -delete

echo "== install by name (PluginInstaller as www-data)"
pi() {
    (cd "$W" && sudo -u www-data php -r 'require "includes/config.php"; require "includes/autoload.php";
        try { var_export(\RaspAP\Plugins\PluginInstaller::getInstance()->installPluginByName($argv[1])); }
        catch (Exception $e) { echo "EXC: ".$e->getMessage(); }' -- "$1" 2>&1)
}
out=$(pi Firewall)
c "Firewall (bundled): $out" '[ "$out" = true ] && [ "$(readlink "$W/plugins/Firewall")" = "$W/plugins-available/Firewall" ] && grep -q "raspap-firewall.sh apply" /etc/sudoers.d/090_Firewall && ! grep -q /tmp /etc/sudoers.d/090_Firewall && [ -f "$W/app/js/plugins/Firewall.js" ]'
out=$(pi Wireshark)
c "Wireshark (bundled, manifest name TShark): $out" '[ "$out" = true ] && [ -f /etc/sudoers.d/090_TShark ]'
out=$(pi "Unknown plugin")
c "a name that is not in the list is refused" 'echo "$out" | grep -q "not in the plugin list"'
out=$(pi "../../etc")
c "a path as name is refused" 'echo "$out" | grep -q "not in the plugin list"'
c "PluginInstaller::installPlugin is private" '! (cd "$W" && php -r "require \"includes/config.php\"; require \"includes/autoload.php\"; \$r = new ReflectionMethod(\"RaspAP\\\\Plugins\\\\PluginInstaller\", \"installPlugin\"); exit(\$r->isPublic() ? 0 : 1);")'
c "do_plugin_install.php and plugins.js use only the name" 'grep -q plugin_name "$W/ajax/plugins/do_plugin_install.php" && ! grep -qE "plugin_uri|install_path|plugin_version" "$W/ajax/plugins/do_plugin_install.php" && ! grep -qE "plugin_uri|install_path" "$W/app/js/ajax/plugins.js"'
out=$(pi DynDNS)
c "DynDNS (downloaded from the list source): $out" '[ "$out" = true ] && [ -d "$W/plugins/DynDNS" ] && [ -f /etc/sudoers.d/090_DynDNS ]'

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
eval "$(sed -n '/^function _migrate_firewall_plugin()/,/^}/p' "$S/installers/common.sh")"
out=$(_migrate_firewall_plugin 2>&1); rc=$?
c "migration ran (rc $rc)" '[ $rc = 0 ]'
c "plugins/Firewall is now the bundled plugin" '[ "$(readlink "$W/plugins/Firewall")" = "$W/plugins-available/Firewall" ]'
c "090_Firewall without /tmp rules, root 440" '! grep -q /tmp /etc/sudoers.d/090_Firewall && grep -q "raspap-firewall.sh apply" /etc/sudoers.d/090_Firewall && [ "$(stat -c %U:%a /etc/sudoers.d/090_Firewall)" = root:440 ]'
c "rules in the own chain, old flat rules gone" 'iptables -S RASPAP_FW_INPUT | grep -q -- "-i lo -j ACCEPT" && ! iptables -S INPUT | grep -q -- "-A INPUT -i lo" && ! iptables -S INPUT | grep -q -- "--state RELATED"'
out=$(_migrate_firewall_plugin 2>&1)
c "second run: nothing to do" '[ -z "$out" ]'

echo "== installer: helpers of the plugins"
systemctl() { :; }
rm -f /usr/local/sbin/raspap-firewall.sh
eval "f() { $(sed -n '/# The root helper of the Firewall plugin, and the files of the Tailscale/,/^    fi$/p' "$S/installers/common.sh") ; }"
f
unset -f sudo systemctl
c "firewall helper, ts-optimize and the tailscale unit installed as root" '[ "$(stat -c %U:%a /usr/local/sbin/raspap-firewall.sh)" = root:755 ] && [ "$(stat -c %U:%a /usr/local/sbin/raspap-ts-optimize.sh)" = root:755 ] && [ "$(stat -c %U:%a /etc/systemd/system/tailscale-ethtool@.service)" = root:644 ]'
c "the update does not run submodule update --remote" '! grep -q "submodule update --remote" "$S/installers/common.sh"'

finish
