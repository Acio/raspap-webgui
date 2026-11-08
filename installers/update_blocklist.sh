#!/bin/bash
#
# RaspAP blocklist update
#
# @author billz
# license: GNU General Public License v3.0
#
# Downloads a blocklist of /etc/raspap/adblock/blocklists.json and installs it
# as hostnames.txt (addn-hosts) or domains.txt (a conf-file of dnsmasq).
# www-data runs this script with sudo. The hardened fork:
# - www-data gives only the name of the list. The URL and the target file
#   come from the root-owned copy of blocklists.json.
# - The script keeps only blocking lines. dnsmasq reads domains.txt as its
#   configuration, so other options in a list (for example a script that
#   dnsmasq runs as root) must not get into it.
# - A failed or empty download keeps the current list.
#
# Usage: update_blocklist.sh <list name>   update one list, prints the exit status
#        update_blocklist.sh clean         filter the installed lists again

set -o errexit
set -o nounset
set -o pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

readonly adblock_dir="/etc/raspap/adblock"
readonly lists="$adblock_dir/blocklists.json"

die() {
    echo "$2" >&2
    exit "$1"
}

# domains.txt: only server=, address= or local= for domains, to a sink address
filter_domains() {
    grep -E '^(server|address|local)=(/[A-Za-z0-9_.*-]+)+/(#|0\.0\.0\.0|::|127\.0\.0\.1|::1)?$' || true
}

# hostnames.txt: only "<sink address> <name> ..." lines, without comments
filter_hosts() {
    sed -e 's/[[:space:]]*#.*$//' |
        grep -E '^(0\.0\.0\.0|127\.0\.0\.1|::|::1)[[:space:]]+[A-Za-z0-9_.-]+([[:space:]]+[A-Za-z0-9_.-]+)*[[:space:]]*$' || true
}

# filter <file name> < in > out
filter() {
    case "$1" in
        domains.txt) filter_domains ;;
        hostnames.txt) filter_hosts ;;
        *) die 2 "invalid list file $1" ;;
    esac
}

# Replaces $adblock_dir/$1 with the file $2. The list keeps its owner and mode.
replace_list() {
    local target="$adblock_dir/$1" tmp="$2"
    if [ -f "$target" ] && [ ! -L "$target" ]; then
        chown --reference="$target" "$tmp"
        chmod --reference="$target" "$tmp"
    else
        chown root:www-data "$tmp"
        chmod 644 "$tmp"
    fi
    mv -f "$tmp" "$target"
}

# The root-owned copy of blocklists.json, not the copy in the web root
[ -f "$lists" ] && [ ! -L "$lists" ] && [ "$(stat -c %u "$lists")" = 0 ] &&
    [ -z "$(find "$lists" -perm /022)" ] || die 1 "$lists is missing or not owned by root"

[ "$#" -eq 1 ] || die 2 "Usage: $0 <list name> | clean"

if [ "$1" = clean ]; then
    for file in domains.txt hostnames.txt; do
        [ -f "$adblock_dir/$file" ] && [ ! -L "$adblock_dir/$file" ] || continue
        tmp=$(mktemp "$adblock_dir/.$file.XXXXXX")
        filter "$file" < "$adblock_dir/$file" > "$tmp"
        if cmp -s "$tmp" "$adblock_dir/$file"; then
            rm -f "$tmp"
        else
            echo "$file: removed $(($(wc -l < "$adblock_dir/$file") - $(wc -l < "$tmp"))) lines that are not blocking lines"
            replace_list "$file" "$tmp"
        fi
    done
    exit 0
fi

name="$1"
entry=$(jq -r --arg name "$name" '[.[] | to_entries[] | select(.key == $name) | .value] | first // empty | "\(.list_url) \(.dest_file)"' "$lists") ||
    die 1 "Unable to read $lists"
[ -n "$entry" ] || die 2 "Unknown blocklist: $name"
url="${entry% *}"
file="${entry##* }"
[[ "$url" =~ ^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._~/%+-]*)?$ ]] || die 2 "Invalid URL of $name"
[ "$file" = hostnames.txt ] || [ "$file" = domains.txt ] || die 2 "Invalid list file of $name"

# download and filter to temporary files in the list directory
raw=$(mktemp "$adblock_dir/.$file.raw.XXXXXX")
tmp=$(mktemp "$adblock_dir/.$file.XXXXXX")
trap 'rm -f "$raw" "$tmp"' EXIT
status=0
wget -q --no-use-server-timestamps -O "$raw" -- "$url" &> /dev/null || status=$?
if [ "$status" -eq 0 ]; then
    filter "$file" < "$raw" > "$tmp"
    if [ ! -s "$tmp" ]; then
        echo "The list has no blocking lines" >&2
        status=1
    else
        dropped=$(($(grep -cvE '^[[:space:]]*(#|$)' "$raw" || true) - $(wc -l < "$tmp")))
        [ "$dropped" -le 0 ] || echo "Removed $dropped lines that are not blocking lines" >&2
        replace_list "$file" "$tmp"
    fi
fi
echo "$status"
