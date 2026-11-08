#!/bin/bash
#
# RaspAP plugin helper (hardened fork)
#
# Description: Installs a plugin of the plugin list. www-data runs this
# script with sudo and gives only the name of the plugin. Everything else
# comes from root-owned copies that the installer makes:
# - /etc/raspap/plugins/plugins.json, the plugin list of the release: the
#   sudo rules, packages, configuration files, permissions and JavaScript;
# - /etc/raspap/plugins/available/<plugin>, the bundled plugin files.
# The script checks the complete entry first. Only then does it change the
# system, and a failed step removes the changes of the earlier steps.
# Installed as /etc/raspap/plugins/plugin_helper.sh.
# License: GNU General Public License v3.0
#
# You are not obligated to bundle the LICENSE file with your RaspAP projects as long
# as you leave these references intact in the header comments of your source files.
#
# Usage: plugin_helper.sh install <name>   the name of the plugin list, for example "NTP Server"
#
# Exit status: 0 installed, 1 system error, 2 refused, 3 already installed

set -o errexit
set -o nounset
set -o pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

readonly raspap_user="www-data"
readonly webroot_dir="/var/www/html"
readonly plugins_dir="/etc/raspap/plugins"
readonly list="$plugins_dir/plugins.json"
readonly available="$plugins_dir/available"

# A plugin must not change the files of RaspAP and of the system
readonly protected_paths=(
    /bin /boot /dev /etc/sudoers /etc/sudoers.d /etc/passwd /etc/shadow
    /etc/group /etc/gshadow /etc/systemd /etc/udev /etc/iptables /etc/nftables.conf
    /etc/wireguard /etc/openvpn /etc/hostapd /etc/dnsmasq.conf /etc/dnsmasq.d
    /etc/dhcpcd.conf /etc/wpa_supplicant /etc/NetworkManager /etc/network
    /etc/lighttpd /etc/php /etc/apt /etc/cron.d /etc/cron.hourly /etc/cron.daily
    /etc/cron.weekly /etc/cron.monthly /etc/crontab /etc/ssh /etc/logrotate.d
    /etc/logrotate.conf /etc/ld.so.preload /etc/ld.so.conf /etc/ld.so.conf.d
    /etc/pam.d /etc/profile /etc/profile.d /etc/bash.bashrc /etc/environment
    /etc/default /etc/init.d /etc/rc.local /etc/modprobe.d /etc/modules-load.d
    /etc/security /etc/polkit-1 /etc/dbus-1 /etc/raspap /lib /lib64 /proc /root
    /run /sbin /sys /usr /var/lib /var/spool "$webroot_dir"
)
# Exceptions in the protected paths: plugin data in the web root
readonly webroot_data=("$webroot_dir/plugins" "$webroot_dir/app/js/plugins" "$webroot_dir/config")
# www-data can write in these directories
readonly writable_dirs=(/tmp /var/tmp /dev/shm /run/user /home "$webroot_dir" /etc/raspap)

die() {
    echo "Error: $2" >&2
    exit "$1"
}

usage() {
    echo "Usage: $0 install <name>" >&2
    exit 2
}

# Returns 0 when $1 is equal to or below one of the following paths
below() {
    local path="$1" p
    shift
    for p in "$@"; do
        if [ "$path" = "$p" ] || [[ "$path" == "$p"/* ]]; then
            return 0
        fi
    done
    return 1
}

# A sudo rule of a plugin: for www-data, one command, a program that www-data
# can not change, and arguments without wildcards and temporary directories
check_rule() {
    local rule="$1" cmd prog args
    [[ "$rule" =~ ^www-data\ ALL=\(ALL\)\ NOPASSWD:(/[^,]+)$ ]] || die 2 "refused sudo rule (format): $rule"
    cmd="${BASH_REMATCH[1]}"
    prog="${cmd%% *}"
    args=""
    [ "$prog" = "$cmd" ] || args="${cmd#* }"
    [[ "$prog" =~ ^/[A-Za-z0-9_./-]+$ ]] || die 2 "refused sudo rule (program): $rule"
    if below "$(realpath -m -- "$prog")" "${writable_dirs[@]}"; then
        die 2 "refused sudo rule (www-data can change $prog): $rule"
    fi
    if [ -e "$prog" ] && { [ "$(stat -L -c %u "$prog")" != 0 ] || [ -n "$(find -L "$prog" -maxdepth 0 -perm /022)" ]; }; then
        die 2 "refused sudo rule (other users can change $prog): $rule"
    fi
    if [[ "$args" == *[\*\?\[\]\\!\"\'\$\`]* ]]; then
        die 2 "refused sudo rule (wildcard or special character): $rule"
    fi
    if [[ " $args" =~ [[:space:]]/(tmp|var/tmp|dev/shm|run/user)(/|[[:space:]]|$) ]]; then
        die 2 "refused sudo rule (temporary directory): $rule"
    fi
}

# A destination of a configuration file: absolute, and not a file of RaspAP
# or of the system (plugin data in the web root is allowed)
check_destination() {
    local dest
    dest="$(realpath -m -- "$1")"
    [[ "$1" == /* ]] || die 2 "refused destination (not absolute): $1"
    below "$dest" "${webroot_data[@]}" && return 0
    if [ "$dest" = / ] || below "$dest" "${protected_paths[@]}"; then
        die 2 "refused destination (protected): $1"
    fi
}

# A file of the plugin, relative to the plugin directory: no "..", a regular
# file, not a link
plugin_file() {
    local rel="$1"
    [[ "$rel" =~ ^[A-Za-z0-9_][A-Za-z0-9_./@-]*$ ]] && [[ "/$rel/" != */../* ]] || die 2 "refused plugin file name: $rel"
    [ -f "$src/$rel" ] && [ ! -L "$src/$rel" ] || die 2 "the plugin has no file $rel"
    # also no linked directory on the way out of the plugin
    [[ "$(realpath -- "$src/$rel")" == "$(realpath -- "$src")"/* ]] || die 2 "refused plugin file (outside the plugin): $rel"
}

[ "$#" -eq 2 ] && [ "$1" = install ] || usage
name="$2"
[ "$(id -u)" = 0 ] || die 1 "run this script as root"
command -v jq > /dev/null || die 1 "jq is missing"

# the root-owned plugin list of the release
[ -f "$list" ] && [ ! -L "$list" ] && [ "$(stat -c %u "$list")" = 0 ] &&
    [ -z "$(find "$list" -perm /022)" ] || die 1 "$list is missing or not owned by root"
entry=$(jq -c --arg n "$name" '[(.plugins // .)[] | select(.name == $n)] | first // empty' "$list") ||
    die 1 "unable to read $list"
[ -n "$entry" ] || die 2 "the plugin is not in the plugin list: $name"
field() { jq -r "$1" <<< "$entry"; }

reason=$(field '.unavailable // empty')
[ -z "$reason" ] || die 2 "$name is not available in the hardened fork: $reason"
[ "$(field '.install_path // empty')" = plugins-available ] ||
    die 2 "$name: the hardened fork installs only bundled plugins"
for key in keys dpkgs user_nonprivileged; do
    [ "$(field "(.$key // []) | length")" = 0 ] || die 2 "$name: \"$key\" is not supported in the hardened fork"
done

dir=$(basename "$(field '.plugin_uri // empty')")
[[ "$dir" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || die 2 "$name: invalid plugin directory"
plugin_name="${name// /}"
[[ "$plugin_name" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || die 2 "invalid plugin name: $name"
src="$available/$dir"
[ -d "$src" ] && [ ! -L "$src" ] && [ "$(stat -c %u "$src")" = 0 ] || die 1 "$src is missing or not owned by root"
target="$webroot_dir/plugins/$dir"
if [ -e "$target" ] || [ -L "$target" ]; then
    echo "$name is already installed" >&2
    exit 3
fi

# 1. check the complete entry
mapfile -t rules < <(field '.sudoers[]?')
for rule in "${rules[@]}"; do
    check_rule "$rule"
done
mapfile -t packages < <(field '(.dependencies // {}) | keys[]')
for package in "${packages[@]}"; do
    [[ "$package" =~ ^[a-z0-9][a-z0-9+.-]{1,63}$ ]] || die 2 "refused package name: $package"
done
config_src=() config_dest=()
while IFS=$'\t' read -r s d; do
    [ -n "$s" ] || continue
    plugin_file "$s"
    [[ "$d" == */ ]] && d="$d$(basename "$s")"
    check_destination "$d"
    if [ -L "$d" ] || [ -d "$d" ]; then
        die 2 "refused destination (a link or a directory): $d"
    fi
    config_src+=("$s")
    config_dest+=("$d")
done < <(field '.configuration[]? | [.source, .destination] | @tsv')
perm_file=() perm_owner=() perm_group=() perm_mode=()
while IFS=$'\t' read -r f o g m; do
    [ -n "$f" ] || continue
    printf '%s\n' "${config_dest[@]}" | grep -qxF -- "$f" || die 2 "refused permissions: $f is not a configuration file of the plugin"
    [[ "$o" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$g" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$m" =~ ^0?[0-7]{3}$ ]] ||
        die 2 "refused permissions: invalid owner, group or mode for $f"
    if ! below "$(realpath -m -- "$f")" "${webroot_data[@]}" && { [ "$o" != root ] || [ "$g" != root ] || [ $((8#$m & 8#022)) != 0 ]; }; then
        die 2 "refused permissions: a file outside the web root must belong to root and not be writable by others: $f"
    fi
    perm_file+=("$f") perm_owner+=("$o") perm_group+=("$g") perm_mode+=("$m")
done < <(field '.permissions[]? | [.file, .owner, .group, .mode] | @tsv')
mapfile -t scripts < <(field '.javascript | if type == "object" then .source elif type == "array" then .[] elif type == "string" then . else empty end')
for js in "${scripts[@]}"; do
    plugin_file "$js"
    [[ "$js" == *.js ]] || die 2 "refused JavaScript file: $js"
done

# 2. install. A failed step removes the changes of the earlier steps.
undo=()
rollback() {
    local i
    for ((i = ${#undo[@]} - 1; i >= 0; i--)); do
        rm -f -- "${undo[$i]}"
    done
}
trap 'rc=$?; [ "$rc" = 0 ] || rollback; exit $rc' EXIT

if [ "${#rules[@]}" -gt 0 ]; then
    rules_file="/etc/sudoers.d/090_$plugin_name"
    tmp=$(mktemp /etc/sudoers.d/.plugin.XXXXXX)
    undo+=("$tmp")
    printf '%s\n' "${rules[@]}" > "$tmp"
    chown root:root "$tmp"
    chmod 0440 "$tmp"
    visudo -cqf "$tmp" || die 2 "visudo refused the sudo rules of $name"
    mv -f "$tmp" "$rules_file"
    undo+=("$rules_file")
fi
if [ "${#packages[@]}" -gt 0 ]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends -- "${packages[@]}" >&2 ||
        die 1 "unable to install the packages of $name"
fi
for i in "${!config_src[@]}"; do
    d="${config_dest[$i]}"
    [ -e "$d" ] || undo+=("$d")
    mkdir -p -- "$(dirname "$d")"
    if below "$(realpath -m -- "$d")" "${webroot_data[@]}"; then
        install -o "$raspap_user" -g "$raspap_user" -m 644 -- "$src/${config_src[$i]}" "$d"
    else
        install -o root -g root -m 644 -- "$src/${config_src[$i]}" "$d"
    fi
done
for i in "${!perm_file[@]}"; do
    chown "${perm_owner[$i]}:${perm_group[$i]}" -- "${perm_file[$i]}"
    chmod "${perm_mode[$i]}" -- "${perm_file[$i]}"
done
if [ "${#scripts[@]}" -gt 0 ]; then
    install -d -o "$raspap_user" -g "$raspap_user" -m 755 "$webroot_dir/app/js/plugins"
fi
for js in "${scripts[@]}"; do
    d="$webroot_dir/app/js/plugins/$(basename "$js")"
    [ -e "$d" ] || undo+=("$d")
    install -o "$raspap_user" -g "$raspap_user" -m 644 -- "$src/$js" "$d"
done
ln -s -- "$webroot_dir/plugins-available/$dir" "$target"
undo+=("$target")
chown -h "$raspap_user:$raspap_user" "$target"

echo "OK"
