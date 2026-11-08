# NTP Server
A Network Time Protocol (NTP) server for RaspAP

## Hardened fork

This copy of the NTP Server plugin (billz/NTPServer v1.1.2) is changed for the hardened fork of RaspAP (Acio/raspap-webgui), 2026-11-08. The plugin writes `ntp.conf` and controls ntpd only through the root helper `/usr/local/sbin/raspap-ntp.sh`. The helper accepts only the directives of the Debian configuration, with fixed file paths. The plugin does not write `/tmp/ntpdata`, and it has no sudo rules with a wildcard.
