# Firewall
A firewall plugin that implements an iptables rule set

## Hardened fork

This copy of the Firewall plugin is changed for the hardened fork of RaspAP (Acio/raspap-webgui), 2026-11-06. The root helper `/usr/local/sbin/raspap-firewall.sh` makes the rules from a fixed rule set and the checked values of `firewall.conf`, in the own chains `RASPAP_FW_INPUT`, `RASPAP_FW_OUTPUT`, `RASPAP_FW_FORWARD` and `RASPAP_FW_POSTROUTING`. The plugin does not run scripts from `/tmp` as root, and it does not remove the rules of the WireGuard kill switch, the WireGuard forwarding, the captive portal or the NAT of the access point.
