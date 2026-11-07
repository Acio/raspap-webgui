#!/bin/bash
#
# RaspAP RestAPI key helper
#
# Description: Writes the RestAPI key to /etc/raspap/api/.env. www-data runs
# this script with sudo, and gives the key on stdin, so the key is not in the
# process list. The script checks the key, keeps the other lines of .env, and
# writes the file as root:www-data 640, because systemd gives the key to the
# RestAPI service and the web interface shows it. Before, www-data moved a
# file of its own to .env, which then belonged to www-data.
# Installed as /usr/local/sbin/raspap-api-key.sh.
# License: GNU General Public License v3.0
#
# You are not obligated to bundle the LICENSE file with your RaspAP projects as long
# as you leave these references intact in the header comments of your source files.
#
# Usage: raspap-api-key.sh set   (the key on stdin, one line)

set -o errexit
set -o nounset
set -o pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

readonly env_file="/etc/raspap/api/.env"

die() {
    echo "$2" >&2
    exit "$1"
}

[ "$#" -eq 1 ] && [ "$1" = set ] || die 2 "Usage: $0 set (the key on stdin)"
[ -d "$(dirname "$env_file")" ] || die 1 "no directory $(dirname "$env_file")"

IFS= read -r key || [ -n "${key:-}" ] || die 2 "no key on stdin"
# the same characters as the check of includes/restapi.php
[[ "$key" =~ ^[A-Za-z0-9._~+/=-]{8,128}$ ]] || die 2 "invalid key: use 8 to 128 letters, digits or . _ ~ + / = -"

tmp="$(mktemp "$env_file.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
if [ -f "$env_file" ] && [ ! -L "$env_file" ]; then
    grep -v '^RASPAP_API_KEY=' "$env_file" > "$tmp" || true
fi
echo "RASPAP_API_KEY=$key" >> "$tmp"
chown root:www-data "$tmp"
chmod 640 "$tmp"
mv -f "$tmp" "$env_file"
trap - EXIT
echo "OK"
