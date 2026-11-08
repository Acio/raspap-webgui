#!/bin/bash
#
# Ad blocking and dnsmasq: the blocklist update script takes only a list name
# and reads the URL from its root-owned list, it keeps only blocking lines,
# and the config file helper accepts only the dnsmasq options of the web
# interface and only hosts lines in the custom blocklist.

. /s/tests/fork/lib.sh

echo "== setup"
setup_sudoers
A=/etc/raspap/adblock
mkdir -p $A /opt/stub
install -o root -g root -m 750 "$S/installers/update_blocklist.sh" $A/update_blocklist.sh
cat > $A/blocklists.json <<'EOF'
{
  "Test": {
    "hosts": { "list_url": "https://lists.example.org/hosts.txt", "dest_file": "hostnames.txt" },
    "domains": { "list_url": "https://lists.example.org/domains.txt", "dest_file": "domains.txt" },
    "evil": { "list_url": "https://lists.example.org/evil.txt", "dest_file": "domains.txt" },
    "missing": { "list_url": "https://lists.example.org/missing.txt", "dest_file": "domains.txt" },
    "empty": { "list_url": "https://lists.example.org/empty.txt", "dest_file": "domains.txt" },
    "local": { "list_url": "https://lists.example.org/dnsmasq/light.txt", "dest_file": "domains.txt" },
    "plain http": { "list_url": "http://lists.example.org/domains.txt", "dest_file": "domains.txt" },
    "bad file": { "list_url": "https://lists.example.org/domains.txt", "dest_file": "../../etc/x.txt" }
  }
}
EOF
chown root:root $A/blocklists.json; chmod 644 $A/blocklists.json
# wget is replaced by a stub that serves these lists
cat > /opt/stub/wget <<'EOF'
#!/bin/bash
out="" url=""
while [ $# -gt 0 ]; do case "$1" in -O) out="$2"; shift 2 ;; --) url="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac; done
case "$url" in
    */hosts.txt) printf '# header\n127.0.0.1 localhost\nff02::1 ip6-allnodes\n0.0.0.0 ads.example.com\n0.0.0.0 a.example b.example # comment\n203.0.113.9 bank.example\n' > "$out" ;;
    */domains.txt) printf '# oisd\nserver=/ads.example/\nserver=/tracker.example/\n' > "$out" ;;
    */evil.txt) printf 'server=/ads.example/\ndhcp-script=/tmp/x.sh\nconf-file=/tmp/y\n server=/z/\nserver=/bank.example/203.0.113.9\naddress=/b.example/0.0.0.0\n' > "$out" ;;
    */empty.txt) printf '# nothing\n' > "$out" ;;
    */dnsmasq/light.txt) printf '# HaGeZi format\nlocal=/adminpanel.example/\nlocal=/telemetry.example.com/\n' > "$out" ;;
    *) exit 8 ;;
esac
EOF
chmod 755 /opt/stub/wget
# the script sets its own PATH: /usr/local/bin comes first
cp /opt/stub/wget /usr/local/bin/wget
ub() { PATH="/opt/stub:$PATH" sudo -u www-data env PATH="/opt/stub:$PATH" sudo -n $A/update_blocklist.sh "$@" 2>&1; }
reset() { printf 'server=/old.example/\n' > $A/domains.txt; printf '0.0.0.0 old.example\n' > $A/hostnames.txt; chown root:www-data $A/*.txt; chmod 644 $A/*.txt; }

echo "== update by name"
reset; out=$(PATH="/opt/stub:$PATH" $A/update_blocklist.sh hosts 2>&1)
c "hosts list: only sink lines, comments removed" '[ "$(tail -1 <<< "$out")" = 0 ] && grep -qx "0.0.0.0 ads.example.com" $A/hostnames.txt && grep -qx "0.0.0.0 a.example b.example" $A/hostnames.txt && ! grep -qE "bank|ff02|#" $A/hostnames.txt && [ "$(stat -c %U:%G:%a $A/hostnames.txt)" = root:www-data:644 ]'
reset; PATH="/opt/stub:$PATH" $A/update_blocklist.sh domains > /dev/null 2>&1
c "domains list installed" 'grep -qx "server=/tracker.example/" $A/domains.txt && ! grep -q old.example $A/domains.txt'
reset; out=$(PATH="/opt/stub:$PATH" $A/update_blocklist.sh evil 2>&1)
c "options and redirects removed from a domains list" 'grep -qx "server=/ads.example/" $A/domains.txt && grep -qx "address=/b.example/0.0.0.0" $A/domains.txt && [ "$(wc -l < $A/domains.txt)" = 2 ] && echo "$out" | grep -q "Removed 4 lines"'
for l in missing empty "plain http" "bad file" "no such list"; do
    reset; PATH="/opt/stub:$PATH" $A/update_blocklist.sh "$l" > /dev/null 2>&1
    c "$l: the old lists stay, no temporary files" 'grep -q old.example $A/domains.txt && grep -q old.example $A/hostnames.txt && [ -z "$(ls -A $A | grep "^\.")" ] && [ ! -e /etc/x.txt ]'
done
c "the old URL arguments are refused" '! PATH="/opt/stub:$PATH" $A/update_blocklist.sh https://lists.example.org/domains.txt domains.txt $A/ > /dev/null 2>&1'
chown www-data $A/blocklists.json
c "a blocklists.json that root does not own is refused" '! PATH="/opt/stub:$PATH" $A/update_blocklist.sh domains > /dev/null 2>&1'
chown root $A/blocklists.json
reset; out=$(ub domains)
c "www-data can run it with sudo" 'grep -qx "server=/tracker.example/" $A/domains.txt'
printf 'server=/ok.example/\ndhcp-script=/tmp/x\n# c\n' > $A/domains.txt
out=$($A/update_blocklist.sh clean 2>&1)
c "clean: the installed lists are filtered again" '[ "$(cat $A/domains.txt)" = "server=/ok.example/" ] && echo "$out" | grep -q "domains.txt: removed"'
out=$($A/update_blocklist.sh clean 2>&1)
c "clean: no change the second time" '[ -z "$out" ]'
c "update_blocklist.php sends only the list name" 'grep -q "escapeshellarg(\$blocklist_id)" "$S/ajax/adblock/update_blocklist.php" && ! grep -q "list_url = " "$S/ajax/adblock/update_blocklist.php"'

echo "== the installer"
c "the installer installs the script and a root-owned blocklists.json" 'grep -q "install -o root -g root -m 644 \"\$webroot_dir/config/blocklists.json\" \"\$raspap_dir/adblock/blocklists.json\"" "$S/installers/common.sh"'
c "no list downloads to fixed /tmp names" '! grep -qE "/tmp/(hostnames|domains)\.txt" "$S/installers/common.sh"'
reset; PATH="/opt/stub:$PATH" $A/update_blocklist.sh local > /dev/null 2>&1
c "local=/.../ lines (the HaGeZi dnsmasq format) are kept" '[ "$(cat $A/domains.txt)" = "local=/adminpanel.example/
local=/telemetry.example.com/" ]'
c "each list of blocklists.json: an https URL that the script accepts, and a known list file" 'jq -r ".[] | .[] | \"\(.list_url) \(.dest_file)\"" "$S/config/blocklists.json" | while read -r u f; do [[ "$u" =~ ^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._~/%+-]*)?$ ]] && { [ "$f" = hostnames.txt ] || [ "$f" = domains.txt ]; } || exit 1; done'
c "the HaGeZi lists use the dnsmasq files (the hosts files give 404)" '[ "$(jq -r "[.\"HaGeZi/domains\"[] | select((.list_url | test(\"/dnsmasq/\")) and .dest_file == \"domains.txt\")] | length" "$S/config/blocklists.json")" = 5 ] && ! grep -q "dns-blocklists/main/hosts/" "$S/config/blocklists.json"'
c "the default lists of the installer are in blocklists.json" 'for n in "StevenBlack/hosts (default)" "oisd/big (default)"; do jq -e --arg n "$n" "[.[] | has(\$n)] | any" "$S/config/blocklists.json" > /dev/null || exit 1; done'

echo "== dnsmasq options (raspap-config-file.sh)"
install -o root -g root -m 755 "$S/installers/config-file.sh" /usr/local/sbin/raspap-config-file.sh
mkdir -p /etc/dnsmasq.d
cf() { printf '%b' "$2" | /usr/local/sbin/raspap-config-file.sh install dnsmasq "$1" 2>&1; }
out=$(cf wlan0 '# RaspAP wlan0\ninterface=wlan0\ndomain-needed\ndhcp-range=10.3.141.50,10.3.141.254,255.255.255.0,12h\ndhcp-option=6,9.9.9.9,1.1.1.1\ndhcp-host=aa:bb:cc:dd:ee:ff,10.3.141.20\nserver=9.9.9.9\nno-resolv\nlog-dhcp\nlog-queries\n')
c "the options of the web interface are accepted" '[ -f /etc/dnsmasq.d/090_wlan0.conf ] && grep -q dhcp-host /etc/dnsmasq.d/090_wlan0.conf'
out=$(cf uap0 'interface=lo,uap0               # comment\nbind-dynamic                    # comment\nserver=8.8.8.8                  # comment\nbogus-priv\n')
c "the uap0 lines with comments are accepted" '[ -f /etc/dnsmasq.d/090_uap0.conf ]'
out=$(cf raspap 'log-facility=/var/log/dnsmasq.log\nconf-dir=/etc/dnsmasq.d\n')
c "the default file is accepted" '[ -f /etc/dnsmasq.d/090_raspap.conf ]'
out=$(cf adblock 'conf-file=/etc/raspap/adblock/domains.txt\naddn-hosts=/etc/raspap/adblock/hostnames.txt\naddn-hosts=/etc/raspap/adblock/custom.txt\n')
c "the adblock file is accepted" '[ -f /etc/dnsmasq.d/090_adblock.conf ]'
for bad in 'dhcp-script=/tmp/x' 'dhcp-script =/tmp/x' 'dhcp-leasefile=/tmp/l' 'dhcp-hostsfile=/tmp/h' 'conf-file=/tmp/c' \
    'conf-file=/etc/raspap/adblock/../x' 'addn-hosts=/etc/hosts' 'conf-dir=/tmp' 'address=/bank.example/203.0.113.9' \
    'log-facility=/etc/x' 'interface=wlan0 dhcp-script=/x'; do
    rm -f /etc/dnsmasq.d/090_bad.conf
    out=$(cf bad "interface=wlan0\n$bad\n")
    c "refused: $bad" '[ ! -e /etc/dnsmasq.d/090_bad.conf ] && echo "$out" | grep -q "not allowed"'
done

echo "== custom blocklist (addn-hosts)"
mkdir -p /etc/raspap/adblock
out=$(printf '# my list\n0.0.0.0 ads.example\n192.168.1.10 nas.local nas\n::1 v6.example\n' | /usr/local/sbin/raspap-config-file.sh install adblock-custom 2>&1)
c "hosts lines and comments are accepted" 'grep -q nas.local $A/custom.txt'
for bad in 'dhcp-script=/tmp/x' 'ads.example' '0.0.0.0' '0.0.0.0 a;b'; do
    cp $A/custom.txt /tmp/custom.ref
    out=$(printf '%s\n' "$bad" | /usr/local/sbin/raspap-config-file.sh install adblock-custom 2>&1)
    c "refused in custom.txt: $bad" 'cmp -s $A/custom.txt /tmp/custom.ref && echo "$out" | grep -q "invalid line"'
done

finish
