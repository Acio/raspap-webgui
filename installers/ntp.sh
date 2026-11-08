#!/bin/bash
#
# RaspAP NTP helper
#
# Description: Installs the ntpsec configuration of the NTP Server plugin and
# controls ntpd. www-data runs this script with sudo. The configuration comes
# on stdin. The script accepts only the lines of an allowlist: the directives
# of the Debian configuration, with fixed file paths. A configuration with
# another line is refused, and the current ntp.conf stays.
# Installed as /usr/local/sbin/raspap-ntp.sh.
# License: GNU General Public License v3.0
#
# You are not obligated to bundle the LICENSE file with your RaspAP projects as long
# as you leave these references intact in the header comments of your source files.
#
# Usage: raspap-ntp.sh install          install ntp.conf from stdin
#        raspap-ntp.sh check            check a configuration from stdin, install nothing
#        raspap-ntp.sh start|stop|restart
#        raspap-ntp.sh peers            print the peers (ntpq -p)

set -o errexit
set -o nounset
set -o pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

readonly conf_dir="/etc/ntpsec"
readonly conf="$conf_dir/ntp.conf"
readonly service="ntpd.service"
readonly max_bytes=65536

usage() {
    echo "Usage: $0 install|check|start|stop|restart|peers" >&2
    exit 2
}

die() {
    echo "$1" >&2
    exit 1
}

# a host name, an IPv4 address or an IPv6 address
host_re='^[A-Za-z0-9:.][A-Za-z0-9:.-]{0,252}$'
word_re='^[A-Za-z0-9_.:/-]{1,64}$'

# check_line <line>: returns 0 when the line is allowed
check_line() {
    local -a w
    read -r -a w <<< "$1"
    [ "${#w[@]}" -gt 0 ] || return 0
    case "${w[0]}" in
        server|pool|peer)
            [ "${#w[@]}" -ge 2 ] && [[ "${w[1]}" =~ $host_re ]] || return 1
            local i=2
            while [ "$i" -lt "${#w[@]}" ]; do
                case "${w[$i]}" in
                    iburst|burst|prefer|noselect|true|preempt|nts|noval) ;;
                    minpoll|maxpoll|version|ttl)
                        i=$((i + 1))
                        [[ "${w[$i]:-}" =~ ^[0-9]{1,2}$ ]] || return 1 ;;
                    *) return 1 ;;
                esac
                i=$((i + 1))
            done ;;
        restrict|tos|interface|statistics)
            local x
            for x in "${w[@]:1}"; do
                [[ "$x" =~ $word_re ]] || return 1
            done ;;
        driftfile)
            [ "${#w[@]}" -eq 2 ] && [[ "${w[1]}" =~ ^/var/lib/ntpsec/[A-Za-z0-9_.-]+$ ]] || return 1 ;;
        leapfile)
            [ "${#w[@]}" -eq 2 ] && [[ "${w[1]}" =~ ^/usr/share/zoneinfo/[A-Za-z0-9_.-]+$ ]] || return 1 ;;
        statsdir)
            [ "${#w[@]}" -eq 2 ] && [[ "${w[1]}" =~ ^/var/log/ntpsec/?$ ]] || return 1 ;;
        logfile)
            [ "${#w[@]}" -eq 2 ] && [[ "${w[1]}" =~ ^/var/log/ntpsec/[A-Za-z0-9_.-]+$ ]] || return 1 ;;
        filegen)
            # filegen <name> [file <name>] [type <type>] [enable|disable] [link|nolink]
            [[ "${w[1]:-}" =~ ^(loopstats|peerstats|clockstats|rawstats|sysstats|protostats|usestats)$ ]] || return 1
            local i=2
            while [ "$i" -lt "${#w[@]}" ]; do
                case "${w[$i]}" in
                    file)
                        i=$((i + 1))
                        [[ "${w[$i]:-}" =~ ^[A-Za-z0-9_.-]{1,32}$ ]] || return 1 ;;
                    type)
                        i=$((i + 1))
                        [[ "${w[$i]:-}" =~ ^(none|pid|day|week|month|year|age)$ ]] || return 1 ;;
                    enable|disable|link|nolink) ;;
                    *) return 1 ;;
                esac
                i=$((i + 1))
            done ;;
        *) return 1 ;;
    esac
}

# check_config < file: prints the refused lines, returns 1 when there is one
check_config() {
    local line n=0 bad=0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        line="${line%%#*}"
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        if [[ "$line" == *[![:print:][:space:]]* ]] || ! check_line "$line"; then
            echo "line $n is not allowed: $line" >&2
            bad=1
        fi
    done
    return "$bad"
}

[ "$#" -eq 1 ] || usage

case "$1" in
    install|check)
        tmp=$(mktemp "$conf_dir/.ntp.conf.XXXXXX") || die "Unable to create a temporary file"
        trap 'rm -f "$tmp"' EXIT
        head -c "$((max_bytes + 1))" > "$tmp"
        [ "$(stat -c %s "$tmp")" -le "$max_bytes" ] || die "The configuration is too large"
        grep -qvE '^[[:space:]]*(#|$)' "$tmp" || die "The configuration is empty"
        check_config < "$tmp" || die "The configuration is refused. ntp.conf did not change."
        [ "$1" = check ] && exit 0
        chown root:root "$tmp"
        chmod 644 "$tmp"
        mv -f "$tmp" "$conf"
        trap - EXIT
        ;;
    start|stop|restart)
        systemctl "$1" "$service"
        ;;
    peers)
        ntpq -p
        ;;
    *)
        usage
        ;;
esac
