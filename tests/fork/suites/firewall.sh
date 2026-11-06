#!/bin/bash
#
# The root helper of the Firewall plugin (installers/firewall.sh) with real
# iptables rules. The rules of the WireGuard kill switch, the WireGuard
# forwarding, the captive portal and the NAT of the access point must stay.
# Needs NET_ADMIN.

. /s/tests/fork/lib.sh

echo "== setup"
mkdir -p /etc/raspap/networking /etc/iptables /etc/hostapd /etc/wireguard /etc/openvpn/client
install -o root -g root -m 755 "$S/installers/firewall.sh" /usr/local/sbin/raspap-firewall.sh
install -o root -g root -m 755 "$S/installers/raspap-iptables-save.sh" /usr/local/sbin/raspap-iptables-save.sh
setup_sudoers
manifest_sudoers "$S/plugins-available/Firewall/manifest.json" > /etc/sudoers.d/090_Firewall
chmod 440 /etc/sudoers.d/090_Firewall
chown root:www-data /etc/raspap /etc/raspap/networking
chmod 1775 /etc/raspap /etc/raspap/networking
echo "interface=wlan1" > /etc/hostapd/hostapd.conf
ip link add wg0 type dummy && ip link set wg0 up
ip link add tun0 type dummy && ip link set tun0 up
printf '[Interface]\nPrivateKey = SECRETKEY\n[Peer]\nEndpoint = vpn.example.org:51820\n' > /etc/wireguard/wg0.conf
chmod 600 /etc/wireguard/wg0.conf
printf 'client\nremote 203.0.113.7 1194\n<key>\nSECRET\n</key>\n' > /etc/openvpn/client/Test_client.conf
chmod 600 /etc/openvpn/client/Test_client.conf

# other parts of RaspAP: kill switch chain, wg-forward, captive portal, AP NAT
iptables -N RASPAP_KILLSWITCH
iptables -A RASPAP_KILLSWITCH -o wg0 -j RETURN
iptables -A RASPAP_KILLSWITCH -d 192.0.2.0/24 -j REJECT
iptables -I OUTPUT -j RASPAP_KILLSWITCH
iptables -A FORWARD -i wlan1 -o wg0 -m comment --comment raspap-wg-forward-wg0 -j ACCEPT
iptables -t nat -A POSTROUTING -o wg0 -m comment --comment raspap-wg-forward-wg0 -j MASQUERADE
iptables -I FORWARD 1 -i wlan1 -o wlan0 -p tcp --dport 80 -m comment --comment raspap-portal -j ACCEPT
iptables -t nat -A POSTROUTING -j MASQUERADE
# what the old Firewall plugin left: flat rules in INPUT, OUTPUT and FORWARD
for r in "-i lo -j ACCEPT" "-p icmp --icmp-type 8/0 -j ACCEPT" "-p udp --sport 123 -j ACCEPT" \
    "-p udp -m multiport --sports 53,853 -j ACCEPT" "-i wlan1 -j ACCEPT" \
    "-m state --state RELATED,ESTABLISHED -j ACCEPT" "-i wg0 -j ACCEPT" "-s 198.51.100.9 -j ACCEPT" \
    "-p tcp --dport 22 -j ACCEPT" "-p udp -m udp --dport 123 -j ACCEPT"; do
    # shellcheck disable=SC2086
    iptables -A INPUT $r
done
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -o wlan1 -j ACCEPT
iptables -A FORWARD -i wg+ -j ACCEPT
iptables -P INPUT DROP
others() { iptables-save | grep -E "RASPAP_KILLSWITCH|raspap-wg-forward|raspap-portal|^-A POSTROUTING -j MASQUERADE" | sort; }
before_others="$(others)"

# as the GUI writes it: no ntp-enable key
cat > /etc/raspap/networking/firewall.conf <<'EOF'
firewall-enable = 1
ssh-enable = 1
http-enable =
excl-devices = wg0 tun0
excluded-ips = 198.51.100.9
ap-device = wlan1
restricted-ips =
openvpn-enable = 1
wireguard-enable = 1
client-list =
EOF
chown www-data:www-data /etc/raspap/networking/firewall.conf
fw() { sudo -u www-data sudo -n /usr/local/sbin/raspap-firewall.sh "$@" 2>&1; }
rules() { iptables -S RASPAP_FW_INPUT; }

echo "== apply"
out=$(fw apply); rc=$?; echo "  $out"
c "apply as www-data with sudo (rc $rc)" '[ $rc = 0 ]'
c "own chain with the expected rules" 'rules | grep -qx -- "-A RASPAP_FW_INPUT -i wlan1 -j ACCEPT" && rules | grep -qx -- "-A RASPAP_FW_INPUT -p tcp -m tcp --dport 22 -j ACCEPT" && rules | grep -qx -- "-A RASPAP_FW_INPUT -s 198.51.100.9/32 -j ACCEPT" && rules | grep -qx -- "-A RASPAP_FW_INPUT -i wg0 -j ACCEPT"'
c "http off: no 80,443 rule" '! rules | grep -q "80,443"'
c "ntp-enable not in firewall.conf: NTP rule on, as in the old plugin" 'rules | grep -qx -- "-A RASPAP_FW_INPUT -p udp -m udp --dport 123 -j ACCEPT"'
c "one jump each from INPUT, OUTPUT, FORWARD and nat POSTROUTING" '[ "$(iptables -S INPUT | grep -c "j RASPAP_FW_INPUT")" = 1 ] && [ "$(iptables -S OUTPUT | grep -c "j RASPAP_FW_OUTPUT")" = 1 ] && [ "$(iptables -S FORWARD | grep -c "j RASPAP_FW_FORWARD")" = 1 ] && [ "$(iptables -t nat -S POSTROUTING | grep -c "j RASPAP_FW_POSTROUTING")" = 1 ]'
c "INPUT policy DROP" 'iptables -S INPUT | grep -qx -- "-P INPUT DROP"'
c "flat rules of the old plugin removed" '[ "$(iptables -S INPUT | grep -vc -- "-P INPUT\|RASPAP_FW_INPUT")" = 0 ] && ! iptables -S OUTPUT | grep -q -- "-o lo" && ! iptables -S FORWARD | grep -q -- "-A FORWARD -i wg+ -j ACCEPT"'
c "kill switch, wg-forward, captive portal and AP NAT unchanged" '[ "$(others)" = "$before_others" ]'
c "kill switch jump still first in OUTPUT" '[ "$(iptables -S OUTPUT | sed -n 2p)" = "-A OUTPUT -j RASPAP_KILLSWITCH" ]'
c "VPN rules: wg+ forward, tun NAT" 'iptables -S RASPAP_FW_FORWARD | grep -q -- "-i wg+ -j ACCEPT" && iptables -t nat -S RASPAP_FW_POSTROUTING | grep -q -- "-o tun+ -j MASQUERADE"'
c "rules.v4 saved without the kill switch and forward rules" 'grep -q RASPAP_FW_INPUT /etc/iptables/rules.v4 && ! grep -qE "RASPAP_KILLSWITCH|raspap-wg-forward|raspap-portal" /etc/iptables/rules.v4'
c "IPv6 chain and rules.v6" 'ip6tables -S RASPAP_FW_INPUT | grep -q "icmpv6-type 128" && grep -q RASPAP_FW_INPUT /etc/iptables/rules.v6'
s1="$(iptables-save | grep -v "^#" | sed -E "s/\[[0-9]+:[0-9]+\]//")"
fw apply > /dev/null
c "second apply: no change" '[ "$s1" = "$(iptables-save | grep -v "^#" | sed -E "s/\[[0-9]+:[0-9]+\]//")" ]'

echo "== invalid values in firewall.conf (www-data can write the file)"
sed -i "s/^excl-devices = .*/excl-devices = wg0 bad;name eth0\$(x)/; s/^excluded-ips = .*/excluded-ips = 198.51.100.9 1.2.3.999 10.0.0.0\/8 x;y/; s/^ap-device = .*/ap-device = wl an1/" /etc/raspap/networking/firewall.conf
out=$(fw apply); rc=$?
c "warnings, and no rules with the invalid values (rc $rc)" '[ $rc = 0 ] && echo "$out" | grep -q "Ignored invalid interface: bad;name" && echo "$out" | grep -q "Ignored invalid IPv4 address: 1.2.3.999" && ! iptables-save | grep -qE "bad|\\\$\(|1\.2\.3\.999|x;y" && rules | grep -q -- "-s 10.0.0.0/8 -j ACCEPT"'
c "invalid ap-device: the AP of hostapd.conf stays allowed" 'rules | grep -qx -- "-A RASPAP_FW_INPUT -i wlan1 -j ACCEPT"'

echo "== disable and enable (the toggle of the plugin)"
sed -i "s/^firewall-enable = .*/firewall-enable = /" /etc/raspap/networking/firewall.conf
fw apply > /dev/null
c "off: INPUT ACCEPT, no INPUT rules, VPN forward stays, saved" 'iptables -S INPUT | grep -qx -- "-P INPUT ACCEPT" && [ -z "$(rules | grep -- "-A")" ] && iptables -S RASPAP_FW_FORWARD | grep -q "wg+" && sed -n "/^\*filter/,/^COMMIT/p" /etc/iptables/rules.v4 | grep -q "^:INPUT ACCEPT"'
c "off: other RaspAP rules unchanged" '[ "$(others)" = "$before_others" ]'
sed -i "s/^firewall-enable = .*/firewall-enable = 1/" /etc/raspap/networking/firewall.conf
fw apply > /dev/null
c "on again: INPUT DROP, rules back, saved" 'iptables -S INPUT | grep -qx -- "-P INPUT DROP" && rules | grep -q -- "-i wlan1 -j ACCEPT" && sed -n "/^\*filter/,/^COMMIT/p" /etc/iptables/rules.v4 | grep -q "^:INPUT DROP"'

echo "== other actions"
c "www-data can not run other actions or arguments" '! sudo -u www-data sudo -n /usr/local/sbin/raspap-firewall.sh remove > /dev/null 2>&1 && ! sudo -u www-data sudo -n /usr/local/sbin/raspap-firewall.sh apply x > /dev/null 2>&1'
hosts=$(fw vpn-hosts)
c "vpn-hosts: hosts only, no keys" 'echo "$hosts" | grep -qx vpn.example.org && echo "$hosts" | grep -qx 203.0.113.7 && ! echo "$hosts" | grep -q SECRET'
/usr/local/sbin/raspap-firewall.sh remove > /dev/null
c "remove (root): chains gone, INPUT ACCEPT, other rules unchanged" '! iptables -S | grep -q RASPAP_FW && iptables -S INPUT | grep -qx -- "-P INPUT ACCEPT" && [ "$(others)" = "$before_others" ]'

finish
