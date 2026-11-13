#!/bin/bash
#
# The update: release lookup of raspbian.sh, the web root backup, the config.php
# of the device with the update endpoint of the fork, the installed plugins and
# their JavaScript, and the version check of the web interface.

. /s/tests/fork/lib.sh

echo "== raspbian.sh"
c "default repo is the fork" 'grep -q "^    repo=\"Acio/raspap-webgui\"" "$S/installers/raspbian.sh"'
_install_status() { echo "STATUS $*"; [ "$1" = 0 ] || return 1; }
eval "$(sed -n '/^function _get_release()/,/^}/p' "$S/installers/raspbian.sh")"
curl() { echo '{"tag_name": "3.5.9.9", "name": "3.5.9.9"}'; }
out=$( (repo=Acio/raspap-webgui; _get_release && echo "TAG $RASPAP_LATEST") 2>&1 )
c "release lookup reads the tag" 'echo "$out" | grep -qx "TAG 3.5.9.9"'
curl() { echo '{"url":"x","tag_name":"3.5.9.8","name":"3.5.9.8"}'; }
out=$( (repo=Acio/raspap-webgui; _get_release && echo "TAG $RASPAP_LATEST") 2>&1 )
c "release lookup reads the tag from minified JSON" 'echo "$out" | grep -qx "TAG 3.5.9.8"'
curl() { echo '{"message": "Not Found"}'; }
out=$( (repo=Acio/raspap-webgui; _get_release && echo "TAG $RASPAP_LATEST") 2>&1 )
c "no release: the update stops before a download" 'echo "$out" | grep -q "Failed to fetch latest release" && ! echo "$out" | grep -q TAG'
curl() { echo '{"message": "API rate limit exceeded for 192.0.2.1."}'; }
out=$( (repo=Acio/raspap-webgui; _get_release && echo "TAG") 2>&1 )
c "rate limit: the update stops" 'echo "$out" | grep -q "rate limit" && ! echo "$out" | grep -qx TAG'
unset -f curl
# an explicit branch: no release lookup
eval "$(sed -n '/^function _load_installer()/,/^}/p' "$S/installers/raspbian.sh")"
_get_release() { echo "LOOKUP"; RASPAP_LATEST=x; }
wget() { :; }
source() { :; }
_update_raspap() { echo "UPDATE $branch $UPDATE_URL"; }
_fetch_part() { echo /dev/null; }
out=$( (set +u; repo=Acio/raspap-webgui; branch=pi/hardened; update=1; _load_installer) 2>&1 )
c "--branch: no release lookup, files of that branch" '! echo "$out" | grep -q LOOKUP && echo "$out" | grep -q "UPDATE pi/hardened https://raw.githubusercontent.com/Acio/raspap-webgui/pi/hardened/"'
out=$( (set +u; repo=Acio/raspap-webgui; branch=""; update=1; _load_installer) 2>&1 )
c "no --branch: release lookup" 'echo "$out" | grep -q LOOKUP'
unset -f source wget _update_raspap _get_release _fetch_part

echo "== raspbian.sh: installer parts in private temporary files"
eval "$(sed -n '/^function _fetch_part()/,/^}/p' "$S/installers/raspbian.sh")"
_install_status() { echo "STATUS $*"; [ "$1" = 0 ]; }
UPDATE_URL="https://raw.githubusercontent.com/Acio/raspap-webgui/x/"
# a file of another user at the old fixed name
echo 'echo FROM_TMP_FILE' > /tmp/raspap_common.sh; chown www-data /tmp/raspap_common.sh
wget() { local o; while [ $# -gt 0 ]; do [ "$1" = -O ] && o="$2"; shift; done; echo 'echo FROM_RELEASE' > "$o"; }
f=$(_fetch_part common); rc=$?
c "the part goes to a new private file (rc $rc)" '[ $rc = 0 ] && [ -f "$f" ] && [ "$f" != /tmp/raspap_common.sh ] && [ "$(stat -c %U:%a "$f")" = "root:600" ] && grep -q FROM_RELEASE "$f"'
out=$(bash -c "source $f")
c "the downloaded part is loaded, not the file in /tmp" '[ "$out" = FROM_RELEASE ]'
rm -f "$f"
wget() { return 8; }
out=$( (f=$(_fetch_part common) || exit 1; echo "LOADED $f") 2>&1 ); rc=$?
c "a failed download stops the installer (rc $rc)" '[ $rc != 0 ] && ! echo "$out" | grep -q LOADED && echo "$out" | grep -q "Unable to download common.sh"'
unset -f wget
c "raspbian.sh has no fixed /tmp names" '! grep -q "/tmp/raspap_" "$S/installers/raspbian.sh"'

echo "== update of the web root (common.sh, git clone replaced by a copy)"
set +u  # the installer does not use set -u
sudo() { "$@"; }
_install_log() { :; }
_install_status() { [ "$1" = 0 ] || { echo "STATUS $*"; exit 1; }; }
eval "$(sed -n '/^function _backup_webroot()/,/^}/p;/^function _restore_plugin_javascript()/,/^}/p;/^function _download_latest_files()/,/^}/p;/^function _check_for_old_configs()/,/^}/p' "$S/installers/common.sh")"
git() { if [ "$1" = clone ]; then mkdir -p "${*: -1}"; cp -r /new/. "${*: -1}/"; fi; return 0; }
webroot_dir=$W; raspap_dir=/etc/raspap; raspap_user=www-data; update=1; upgrade=0; exclude=""; branch=3.5.9.9; git_source_url=x
mkdir -p /new
(cd "$S" && tar --exclude=.git --exclude=node_modules -cf - .) | tar -xf - -C /new
old() {
    rm -rf "$W"; mkdir -p "$W/includes" "$W/plugins/MyPlugin" "$W/app/js/plugins" "$raspap_dir"
    cp -r /new/plugins-available "$W/"
    echo "OLD $1" > "$W/old-marker.txt"; echo plugin > "$W/plugins/MyPlugin/x"
    ln -s "$W/plugins-available/Firewall" "$W/plugins/Firewall"
    mkdir -p "$W/plugins/NTPServer/templates/app/js"
    echo '{"name":"NTP Server","javascript":{"source":"templates/app/js/NTPServer.js"}}' > "$W/plugins/NTPServer/manifest.json"
    echo "ntp js" > "$W/plugins/NTPServer/templates/app/js/NTPServer.js"
    mkdir -p "$W/plugins/Evil"; echo '{"name":"Evil","javascript":["../../../../etc/hostname"]}' > "$W/plugins/Evil/manifest.json"
    echo old > "$W/app/js/plugins/Firewall.js"
    sed "s/'RASPI_WIREGUARD_ENABLED', false/'RASPI_WIREGUARD_ENABLED', true/" "$S/tests/fork/fixtures/config-upstream.php" > "$W/includes/config.php"
    echo auth > "$raspap_dir/raspap.auth"
    chown -R www-data:www-data "$W"
}
run() {
    ( _check_for_old_configs && _download_latest_files ) > /tmp/upd.log 2>&1
    local r=$?; [ $r = 0 ] || tail -5 /tmp/upd.log | sed 's/^/    log: /'; return $r
}
mkdir -p /tmp/raspap-user-plugins/trap
mkdir -p /tmp/raspap-webgui/trap
old 1; run; rc=$?
b=$(ls -1t /var/backups/raspap-webroot-*.tar.gz 2> /dev/null | head -1)
c "update ran (rc $rc)" '[ $rc = 0 ]'
c "backup made, mode 600" '[ -n "$b" ] && [ "$(stat -c %a "$b")" = 600 ]'
c "backup has the old files and the old config.php" 'tar -tzf "$b" | grep -qx var/www/html/old-marker.txt && tar -xzf "$b" -O var/www/html/includes/config.php | grep -q "RASPI_WIREGUARD_ENABLED., true"'
c "new web root installed" '[ ! -e "$W/old-marker.txt" ] && [ -f "$W/includes/defaults.php" ]'
c "the web root and its installers belong to root until the last step, web root mode 755" '[ "$(stat -c %U:%a "$W")" = root:755 ] && [ "$(stat -c %U "$W/installers")" = root ] && [ "$(stat -c %U "$W/installers/common.sh")" = root ]'
c "the clone is in a private directory, not /tmp/raspap-webgui" '[ -d /tmp/raspap-webgui/trap ]'
c "config.php of the device kept, raspap.auth kept" 'grep -q "RASPI_WIREGUARD_ENABLED., true" "$W/includes/config.php" && [ -f "$raspap_dir/raspap.auth" ]'
c "update check of the device now uses the fork" 'grep -q "^define(.RASPI_API_ENDPOINT., .https://api.github.com/repos/Acio/raspap-webgui/releases/latest.);" "$W/includes/config.php" && [ "$(grep -c RASPI_API_ENDPOINT "$W/includes/config.php")" = 1 ]'
c "the old /tmp error log default in config.php is now /var/log/raspap/error.log" 'grep -qx "define(.RASPI_ERROR_LOG., ./var/log/raspap/error.log.);" "$W/includes/config.php"'
c "php -l on the config.php after the update" 'php -l "$W/includes/config.php" > /dev/null'
c "plugin directories kept" '[ -f "$W/plugins/MyPlugin/x" ] && [ -f "$W/plugins/NTPServer/manifest.json" ]'
c "bundled plugin symlink kept" '[ "$(readlink "$W/plugins/Firewall")" = "$W/plugins-available/Firewall" ]'
c "plugin JavaScript installed again from the plugins" 'cmp -s "$W/app/js/plugins/Firewall.js" "$W/plugins-available/Firewall/templates/app/js/Firewall.js" && [ "$(cat "$W/app/js/plugins/NTPServer.js")" = "ntp js" ] && [ "$(stat -c %U "$W/app/js/plugins/NTPServer.js")" = www-data ]'
c "a manifest path outside the plugin is not installed" '[ ! -e "$W/app/js/plugins/hostname" ]'
c "the fixed /tmp name is not used, no temporary directory left" '[ -d /tmp/raspap-user-plugins/trap ] && [ -z "$(ls -d /tmp/raspap-user-plugins.* 2> /dev/null)" ]'
rm -rf "$W"; tar -xzf "$b" -C /
c "restore with tar -xzf <file> -C / gives the old web root" 'grep -q "OLD 1" "$W/old-marker.txt" && grep -q "RaspAP/raspap-webgui/releases" "$W/includes/config.php"'
for i in 2 3 4 5; do sleep 1; old $i; run; done
c "only the 3 newest backups stay" '[ "$(ls /var/backups/raspap-webroot-*.tar.gz | wc -l)" = 3 ] && tar -xzf "$(ls -1t /var/backups/raspap-webroot-*.tar.gz | head -1)" -O var/www/html/old-marker.txt | grep -q "OLD 5"'
echo "== the error log directory"
eval "$(sed -n '/^function _create_log_directory()/,/^}/p' "$S/installers/common.sh")"
rm -rf /var/log/raspap; printf 'old line\n' > /tmp/raspap_error.log; chmod 644 /tmp/raspap_error.log
( sudo() { "$@"; }; _create_log_directory ) > /dev/null 2>&1; rc=$?
c "the directory is www-data 750, the old /tmp log moved in with mode 640 (rc $rc)" '[ $rc = 0 ] && [ "$(stat -c %U:%a /var/log/raspap)" = www-data:750 ] && [ "$(cat /var/log/raspap/error.log)" = "old line" ] && [ "$(stat -c %U:%a /var/log/raspap/error.log)" = www-data:640 ] && [ ! -e /tmp/raspap_error.log ]'
printf 'newer\n' > /tmp/raspap_error.log
( sudo() { "$@"; }; _create_log_directory ) > /dev/null 2>&1
c "a second run keeps the log, and removes the /tmp log" '[ "$(cat /var/log/raspap/error.log)" = "old line" ] && [ ! -e /tmp/raspap_error.log ]'
rm -rf /var/log/raspap; ln -s /etc /var/log/raspap
( sudo() { "$@"; }; _create_log_directory ) > /dev/null 2>&1; rc=$?
c "a symlink as the log directory is refused (rc $rc)" '[ $rc != 0 ] && [ "$(stat -c %U /etc)" = root ]'
rm -f /var/log/raspap

echo "== lighttpd settings of the fork (51-raspap-hardened.conf)"
eval "$(sed -n '/^function _install_lighttpd_hardening()/,/^}/p' "$S/installers/common.sh")"
mkdir -p /etc/lighttpd/conf-available /etc/lighttpd/conf-enabled /tmp/lt; touch /etc/lighttpd/lighttpd.conf
printf '#!/bin/sh\necho "lighttpd $*" >> /tmp/lt/calls; exit ${LT_RC:-0}\n' > /usr/local/sbin/lighttpd; chmod 755 /usr/local/sbin/lighttpd
printf '#!/bin/sh\necho "systemctl $*" >> /tmp/lt/calls\n' > /usr/local/sbin/systemctl; chmod 755 /usr/local/sbin/systemctl
( sudo() { "$@"; }; _install_status() { echo "STATUS $*"; }; webroot_dir=$S; _install_lighttpd_hardening ) > /dev/null 2>&1
c "installed, enabled after lighttpd -tt, then a reload" '[ "$(stat -c %U:%a /etc/lighttpd/conf-available/51-raspap-hardened.conf)" = root:644 ] && [ "$(readlink /etc/lighttpd/conf-enabled/51-raspap-hardened.conf)" = ../conf-available/51-raspap-hardened.conf ] && grep -q "lighttpd -tt" /tmp/lt/calls && grep -q "try-reload-or-restart lighttpd" /tmp/lt/calls'
rm -f /etc/lighttpd/conf-enabled/51-raspap-hardened.conf; : > /tmp/lt/calls
( export LT_RC=1; sudo() { "$@"; }; _install_status() { echo "STATUS $*"; }; webroot_dir=$S; _install_lighttpd_hardening ) > /tmp/lt/out 2>&1; rc=$?
c "refused by lighttpd: not enabled, no reload, the update goes on (rc $rc)" '[ $rc = 0 ] && [ ! -e /etc/lighttpd/conf-enabled/51-raspap-hardened.conf ] && ! grep -q reload /tmp/lt/calls && grep -q "old configuration stays" /tmp/lt/out'
rm -f /usr/local/sbin/lighttpd /usr/local/sbin/systemctl
c "the file hides the version in the Server header, install and update call the function" 'grep -qx "server.tag = \"\"" "$S/config/51-raspap-hardened.conf" && [ "$(grep -c "^    _install_lighttpd_hardening$" "$S/installers/common.sh")" = 2 ]'

echo "== the update replaces the running raspbian.sh with a new file"
mkdir -p /etc/raspap/system /tmp/wr/installers
# the old loader sleeps, then bash reads its next line from the same offset
printf '#!/bin/bash\nsleep 2\necho old-end\n' > /tmp/old-loader.sh
printf '#!/bin/bash\nsleep 2\necho NEW-LINE-RAN-AS-ROOT\necho new-end\n' > /tmp/wr/installers/raspbian.sh
replace_loader() {
    (webroot_dir=/tmp/wr raspap_dir=/etc/raspap; _install_log() { :; }; _install_status() { echo "STATUS $*"; }
     eval "$(sed -n '/Copying RaspAP install loader/,/Unable to move application update script/p' "$S/installers/common.sh")")
}
install -m 750 /tmp/old-loader.sh /etc/raspap/system/raspbian.sh
(bash /etc/raspap/system/raspbian.sh > /tmp/loader.out 2>&1 &) ; sleep 0.5; replace_loader; sleep 2.5
c "the running loader ends with its own lines, the new file is installed" '[ "$(cat /tmp/loader.out)" = old-end ] && cmp -s /tmp/wr/installers/raspbian.sh /etc/raspap/system/raspbian.sh && [ "$(stat -c %U:%a /etc/raspap/system/raspbian.sh)" = root:750 ] && [ ! -e /etc/raspap/system/.raspbian.sh.new ]'
install -m 750 /tmp/old-loader.sh /etc/raspap/system/raspbian.sh
(bash /etc/raspap/system/raspbian.sh > /tmp/loader.out 2>&1 &) ; sleep 0.5; cp /tmp/wr/installers/raspbian.sh /etc/raspap/system/raspbian.sh; sleep 2.5
c "control: cp over the running loader runs a line of the new file" 'grep -q NEW-LINE-RAN-AS-ROOT /tmp/loader.out'
old 6; mv /var/backups /var/backups.ok; touch /var/backups
run; rc=$?
c "failed backup: the update stops (rc $rc), the old web root stays" '[ $rc != 0 ] && grep -q "OLD 6" "$W/old-marker.txt"'
rm -f /var/backups; mv /var/backups.ok /var/backups
unset -f sudo git
set -u

echo "== order of the install and update steps"
for f in _install_raspap _update_raspap; do
    steps=$(sed -n "/^function $f()/,/^}/p" "$S/installers/common.sh" | grep -oE "^    _[a-z_]+" | tr -d " ")
    c "$f: _change_file_ownership is the last step before _install_complete" '[ "$(echo "$steps" | tail -2 | head -1)" = _change_file_ownership ] && [ "$(echo "$steps" | grep -c _change_file_ownership)" = 1 ]'
done
c "no lighttpd config through a fixed /tmp name" '! grep -q "/tmp/50-raspap-router.conf" "$S/installers/common.sh"'

echo "== version check of the web interface"
cat > /tmp/v.php <<'EOF'
<?php
require '/s/includes/functions.php';
$cases = [['3.5.9', '3.5.9.1', true], ['3.5.9.1', '3.5.9.2', true], ['3.5.9.1', '3.5.9.1', false],
          ['3.5.9.1', '3.5.9', false], ['3.5.9.1', '3.6.0', true], ['3.6.0.1', '3.6.0', false]];
foreach ($cases as [$a, $b, $e]) {
    if (checkReleaseVersion($a, $b) !== $e) { echo "FAIL $a -> $b\n"; exit(1); }
}
preg_match("/'RASPI_VERSION' => '([^']+)'/", file_get_contents('/s/includes/defaults.php'), $m);
preg_match('/(\d+(\.\d+)+)/', $m[1], $mm);
echo ($mm[0] === $m[1] && count(explode('.', $m[1])) === 4) ? "PASS\n" : "FAIL version $m[1]\n";
EOF
out=$(php /tmp/v.php 2>&1)
c "version compare with 4 numbers, RASPI_VERSION has 4 numbers" '[ "$out" = PASS ] || { echo "$out"; false; }'
c "config/config.php: update endpoint of the fork" 'grep -q "repos/Acio/raspap-webgui/releases/latest" "$S/config/config.php"'
# in a web root as the installer makes it (with includes/config.php)
rm -rf "$W"; setup_webroot
# the upstream test makes a session without a password change (RaspAP 3.5.10)
set_admin_password
out=$(cd "$W" && php tests/update/run_tests.php 2>&1); rc=$?
c "tests/update/run_tests.php in the web root (rc $rc)" '[ $rc = 0 ] || { echo "$out" | tail -5; false; }'

finish
