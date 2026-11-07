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
out=$( (set +u; repo=Acio/raspap-webgui; branch=pi/hardened; update=1; _load_installer) 2>&1 )
c "--branch: no release lookup, files of that branch" '! echo "$out" | grep -q LOOKUP && echo "$out" | grep -q "UPDATE pi/hardened https://raw.githubusercontent.com/Acio/raspap-webgui/pi/hardened/"'
out=$( (set +u; repo=Acio/raspap-webgui; branch=""; update=1; _load_installer) 2>&1 )
c "no --branch: release lookup" 'echo "$out" | grep -q LOOKUP'
unset -f source wget _update_raspap _get_release

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
old 1; run; rc=$?
b=$(ls -1t /var/backups/raspap-webroot-*.tar.gz 2> /dev/null | head -1)
c "update ran (rc $rc)" '[ $rc = 0 ]'
c "backup made, mode 600" '[ -n "$b" ] && [ "$(stat -c %a "$b")" = 600 ]'
c "backup has the old files and the old config.php" 'tar -tzf "$b" | grep -qx var/www/html/old-marker.txt && tar -xzf "$b" -O var/www/html/includes/config.php | grep -q "RASPI_WIREGUARD_ENABLED., true"'
c "new web root installed" '[ ! -e "$W/old-marker.txt" ] && [ -f "$W/includes/defaults.php" ]'
c "config.php of the device kept, raspap.auth kept" 'grep -q "RASPI_WIREGUARD_ENABLED., true" "$W/includes/config.php" && [ -f "$raspap_dir/raspap.auth" ]'
c "update check of the device now uses the fork" 'grep -q "^define(.RASPI_API_ENDPOINT., .https://api.github.com/repos/Acio/raspap-webgui/releases/latest.);" "$W/includes/config.php" && [ "$(grep -c RASPI_API_ENDPOINT "$W/includes/config.php")" = 1 ]'
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
old 6; mv /var/backups /var/backups.ok; touch /var/backups
run; rc=$?
c "failed backup: the update stops (rc $rc), the old web root stays" '[ $rc != 0 ] && grep -q "OLD 6" "$W/old-marker.txt"'
rm -f /var/backups; mv /var/backups.ok /var/backups
unset -f sudo git
set -u

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
out=$(cd "$W" && php tests/update/run_tests.php 2>&1); rc=$?
c "tests/update/run_tests.php in the web root (rc $rc)" '[ $rc = 0 ] || { echo "$out" | tail -5; false; }'

finish
