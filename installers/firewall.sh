#!/bin/bash
#
# RaspAP firewall helper
#
# Description: Applies the rules of the Firewall plugin. www-data runs this
# script with sudo. The script reads the settings of the plugin itself, checks
# each value, and makes the rules from a fixed rule set. The rules go into own
# chains, so the script does not remove the rules of the WireGuard kill switch,
# the WireGuard forwarding, the captive portal or the NAT of the access point.
# Installed as /usr/local/sbin/raspap-firewall.sh.
# License: GNU General Public License v3.0
#
# You are not obligated to bundle the LICENSE file with your RaspAP projects as long
# as you leave these references intact in the header comments of your source files.
#
# Usage: raspap-firewall.sh apply      apply the settings of firewall.conf
#        raspap-firewall.sh remove     remove the firewall rules, INPUT policy ACCEPT
#        raspap-firewall.sh vpn-hosts  print the server hosts of the VPN configurations

set -o errexit
set -o nounset
set -o pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

readonly conf="/etc/raspap/networking/firewall.conf"
readonly hostapd_conf="/etc/hostapd/hostapd.conf"
readonly save_v4="/usr/local/sbin/raspap-iptables-save.sh"
readonly rulesv6="/etc/iptables/rules.v6"
readonly lockfile="/run/raspap-firewall.lock"
# own chains: filter INPUT, OUTPUT, FORWARD and nat POSTROUTING
readonly chains="RASPAP_FW_INPUT:INPUT RASPAP_FW_OUTPUT:OUTPUT RASPAP_FW_FORWARD:FORWARD"
readonly nat_chain="RASPAP_FW_POSTROUTING"

usage() {
    echo "Usage: $0 apply|remove|vpn-hosts" >&2
    exit 2
}

valid_iface() {
    [[ "$1" =~ ^[A-Za-z0-9_.-]{1,15}\+?$ ]]
}

valid_ipv4() {
    local ip="${1%/*}" prefix="" o
    if [[ "$1" == */* ]]; then
        prefix="${1#*/}"
        [[ "$prefix" =~ ^[0-9]{1,2}$ ]] && [ "$prefix" -le 32 ] || return 1
    fi
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1}"; do
        [ "$o" -le 255 ] || return 1
    done
}

# Reads firewall.conf. Only known keys, and only values that pass the checks.
declare -A cfg=([firewall-enable]=0 [ssh-enable]=0 [http-enable]=0 [ntp-enable]=0 [ap-device]="" [excl-devices]="" [excluded-ips]="" [restricted-ips]="")
read_conf() {
    local key value
    [ -f "$conf" ] && [ ! -L "$conf" ] || return 0
    while IFS='=' read -r key value; do
        key="${key//[[:space:]]/}"
        value="$(echo "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/')"
        case "$key" in
            firewall-enable|ssh-enable|http-enable|ntp-enable)
                [ "$value" = 1 ] && cfg[$key]=1 || cfg[$key]=0 ;;
            ap-device)
                valid_iface "$value" && cfg[$key]="$value" ;;
            excl-devices|excluded-ips|restricted-ips)
                cfg[$key]="${value//,/ }" ;;
        esac
    done < "$conf"
    return 0
}

# The access point interface, from hostapd.conf
ap_iface() {
    sed -n 's/^interface=\([A-Za-z0-9_.-]\{1,15\}\)$/\1/p' "$hostapd_conf" 2>/dev/null | head -n 1
}

link_up() {
    ip -o link show 2>/dev/null | grep -qE "^[0-9]+: $1[0-9]*[:@]"
}

# Writes the rules for iptables-restore --noflush to stdout. $1 = 4 or 6
make_rules() {
    local v="$1" dev ip
    local -a aps=() excl=() eips=() rips=()
    local ap
    for ap in "${cfg[ap-device]}" "$(ap_iface)"; do
        if [ -n "$ap" ] && [[ ! " ${aps[*]-} " == *" $ap "* ]]; then
            aps+=("$ap")
        fi
    done
    for dev in ${cfg[excl-devices]}; do
        if valid_iface "$dev"; then excl+=("$dev"); else echo "Ignored invalid interface: $dev" >&2; fi
    done
    for ip in ${cfg[excluded-ips]}; do
        if valid_ipv4 "$ip"; then eips+=("$ip"); else echo "Ignored invalid IPv4 address: $ip" >&2; fi
    done
    for ip in ${cfg[restricted-ips]}; do
        if valid_ipv4 "$ip"; then rips+=("$ip"); else echo "Ignored invalid IPv4 address: $ip" >&2; fi
    done

    echo "*filter"
    echo ":RASPAP_FW_INPUT - [0:0]"
    echo ":RASPAP_FW_OUTPUT - [0:0]"
    echo ":RASPAP_FW_FORWARD - [0:0]"
    if [ "${cfg[firewall-enable]}" = 1 ]; then
        echo "-A RASPAP_FW_INPUT -i lo -j ACCEPT"
        echo "-A RASPAP_FW_OUTPUT -o lo -j ACCEPT"
        if [ "$v" = 4 ]; then
            echo "-A RASPAP_FW_INPUT -p icmp -m icmp --icmp-type 8/0 -j ACCEPT"
            echo "-A RASPAP_FW_INPUT -p icmp -m icmp --icmp-type 0/0 -j ACCEPT"
        else
            echo "-A RASPAP_FW_INPUT -p ipv6-icmp -m icmp6 --icmpv6-type 128 -j ACCEPT"
            echo "-A RASPAP_FW_INPUT -p ipv6-icmp -m icmp6 --icmpv6-type 129 -j ACCEPT"
        fi
        echo "-A RASPAP_FW_INPUT -p udp -m udp --sport 123 -j ACCEPT"
        echo "-A RASPAP_FW_INPUT -p udp -m multiport --sports 53,853 -j ACCEPT"
        echo "-A RASPAP_FW_INPUT -p tcp -m multiport --sports 53,853 -j ACCEPT"
        if [ "$v" = 4 ]; then
            for ip in "${rips[@]+"${rips[@]}"}"; do echo "-A RASPAP_FW_INPUT -s $ip -j DROP"; done
        fi
        for ap in "${aps[@]+"${aps[@]}"}"; do
            echo "-A RASPAP_FW_INPUT -i $ap -j ACCEPT"
            echo "-A RASPAP_FW_OUTPUT -o $ap -j ACCEPT"
        done
        echo "-A RASPAP_FW_INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
        [ "${cfg[ssh-enable]}" = 1 ] && echo "-A RASPAP_FW_INPUT -p tcp -m tcp --dport 22 -j ACCEPT"
        [ "${cfg[http-enable]}" = 1 ] && echo "-A RASPAP_FW_INPUT -p tcp -m multiport --dports 80,443 -j ACCEPT"
        for dev in "${excl[@]+"${excl[@]}"}"; do
            echo "-A RASPAP_FW_INPUT -i $dev -j ACCEPT"
            echo "-A RASPAP_FW_OUTPUT -o $dev -j ACCEPT"
        done
        if [ "$v" = 4 ]; then
            for ip in "${eips[@]+"${eips[@]}"}"; do
                echo "-A RASPAP_FW_INPUT -s $ip -j ACCEPT"
                echo "-A RASPAP_FW_INPUT -d $ip -j ACCEPT"
            done
        fi
        [ "${cfg[ntp-enable]}" = 1 ] && echo "-A RASPAP_FW_INPUT -p udp -m udp --dport 123 -j ACCEPT"
    fi
    # the VPN rules of the plugin are active also when the firewall is off
    if [ "$v" = 4 ]; then
        if link_up tun; then
            for ap in "${aps[@]+"${aps[@]}"}"; do
                echo "-A RASPAP_FW_FORWARD -i tun+ -o $ap -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
                echo "-A RASPAP_FW_FORWARD -i $ap -o tun+ -j ACCEPT"
            done
        fi
        link_up wg && echo "-A RASPAP_FW_FORWARD -i wg+ -j ACCEPT"
    fi
    echo "COMMIT"
    if [ "$v" = 4 ]; then
        echo "*nat"
        echo ":$nat_chain - [0:0]"
        link_up tun && echo "-A $nat_chain -o tun+ -j MASQUERADE"
        echo "COMMIT"
    fi
}

# The rules of the old Firewall plugin are in INPUT, OUTPUT and FORWARD
# directly. Removes each rule that the new chains replace.
remove_legacy() {
    local cmd="$1" rules="$2" line chain spec form
    local -a words
    while IFS= read -r line; do
        [[ "$line" == "-A RASPAP_FW_"* ]] || continue
        chain="${line#-A RASPAP_FW_}"; chain="${chain%% *}"
        spec="${line#-A RASPAP_FW_$chain }"
        # the old plugin used -m state instead of -m conntrack
        for form in "$spec" "${spec//-m conntrack --ctstate/-m state --state}"; do
            read -r -a words <<< "$form"
            while "$cmd" -w -D "$chain" "${words[@]}" 2>/dev/null; do :; done
        done
    done <<< "$rules"
    return 0
}

ensure_jumps() {
    local cmd="$1" pair own base
    for pair in $chains; do
        own="${pair%%:*}"; base="${pair#*:}"
        "$cmd" -w -C "$base" -j "$own" 2>/dev/null || "$cmd" -w -A "$base" -j "$own"
    done
    if [ "$cmd" = iptables ]; then
        iptables -w -t nat -C POSTROUTING -j "$nat_chain" 2>/dev/null || iptables -w -t nat -A POSTROUTING -j "$nat_chain"
    fi
}

remove_chains() {
    local cmd="$1" pair own base
    for pair in $chains; do
        own="${pair%%:*}"; base="${pair#*:}"
        while "$cmd" -w -D "$base" -j "$own" 2>/dev/null; do :; done
        "$cmd" -w -F "$own" 2>/dev/null || true
        "$cmd" -w -X "$own" 2>/dev/null || true
    done
    if [ "$cmd" = iptables ]; then
        while iptables -w -t nat -D POSTROUTING -j "$nat_chain" 2>/dev/null; do :; done
        iptables -w -t nat -F "$nat_chain" 2>/dev/null || true
        iptables -w -t nat -X "$nat_chain" 2>/dev/null || true
    fi
}

# Saves the IPv6 rules without the rules of the kill switch and the
# rules with a RaspAP comment, as raspap-iptables-save.sh does for IPv4
save_v6() {
    local tmp
    command -v ip6tables-save > /dev/null || return 0
    mkdir -p "$(dirname "$rulesv6")"
    tmp="$(mktemp "$rulesv6.XXXXXX")"
    if ip6tables-save | grep -vE 'RASPAP_KILLSWITCH6|--comment raspap-' > "$tmp"; then
        chmod 644 "$tmp"
        mv -f "$tmp" "$rulesv6"
    else
        rm -f "$tmp"
        return 1
    fi
}

save_all() {
    "$save_v4" || echo "Unable to save the IPv4 rules" >&2
    save_v6 || echo "Unable to save the IPv6 rules" >&2
}

apply() {
    local v cmd rules policy
    read_conf
    policy=ACCEPT
    [ "${cfg[firewall-enable]}" = 1 ] && policy=DROP
    for v in 4 6; do
        cmd=iptables; [ "$v" = 6 ] && cmd=ip6tables
        command -v "$cmd" > /dev/null || continue
        rules="$(make_rules "$v")"
        # with --noflush, iptables-restore flushes only the chains that it declares
        "$cmd-restore" -w --noflush <<< "$rules"
        ensure_jumps "$cmd"
        remove_legacy "$cmd" "$rules"
        "$cmd" -w -P INPUT "$policy"
    done
    save_all
    echo "Firewall rules applied (INPUT policy $policy)"
}

remove() {
    local cmd
    for cmd in iptables ip6tables; do
        command -v "$cmd" > /dev/null || continue
        remove_chains "$cmd"
        "$cmd" -w -P INPUT ACCEPT
    done
    save_all
    echo "Firewall rules removed (INPUT policy ACCEPT)"
}

# Prints the server hosts of the WireGuard and OpenVPN configurations, one per
# line. Only the host names and addresses, no keys.
vpn_hosts() {
    local f host
    {
        for f in /etc/wireguard/*.conf; do
            [ -f "$f" ] && [ ! -L "$f" ] || continue
            sed -nE 's/^[[:space:]]*[Ee]ndpoint[[:space:]]*=[[:space:]]*\[?([^]]+)\]?:[0-9]+[[:space:]]*$/\1/p' "$f"
        done
        for f in /etc/openvpn/client/*.conf; do
            [ -f "$f" ] && [ ! -L "$f" ] || continue
            sed -nE 's/^[[:space:]]*remote[[:space:]]+([^[:space:]]+).*$/\1/p' "$f"
        done
    } | while read -r host; do
        if [[ "$host" =~ ^[A-Za-z0-9.:-]{1,253}$ ]]; then echo "$host"; fi
    done | sort -u
}

[ "$#" -eq 1 ] || usage
exec 9> "$lockfile"
flock 9
case "$1" in
    apply) apply ;;
    remove) remove ;;
    vpn-hosts) vpn_hosts ;;
    *) usage ;;
esac
