#!/bin/bash
#
# The RestAPI as the system user raspap-api: the user and the unit of the
# installer, the modules of api/requirements.txt (as the installer installs
# them), the key check, and the endpoints that can not read their files.
# Needs internet access (pip).

. /s/tests/fork/lib.sh

echo "== installer: user and unit"
_install_status() { [ "$1" = 0 ] || { echo "STATUS $*"; exit 1; }; }
_install_log() { :; }
sudo() { "$@"; }
webroot_dir=/tmp/web
mkdir -p "$webroot_dir/installers"
cp "$S/installers/restapi.service" "$webroot_dir/installers/"
block="$(sed -n '/# The service runs as the system user raspap-api, not as root/,/Unable to set restapi service user"/p' "$S/installers/common.sh")"
eval "$block"
c "user raspap-api: system user, nologin, no home" 'id raspap-api > /dev/null && [ "$(getent passwd raspap-api | cut -d: -f6,7)" = "/nonexistent:/usr/sbin/nologin" ] && [ "$(id -u raspap-api)" -lt 1000 ] && [ ! -e /nonexistent ]'
c "unit: User=raspap-api" 'grep -qx "User=raspap-api" "$webroot_dir/installers/restapi.service"'
eval "$block"
c "second run: no error, one user" '[ "$(getent passwd raspap-api | wc -l)" = 1 ]'
unset -f sudo

echo "== modules of api/requirements.txt, system-wide as the installer does"
out=$(python3 -m pip install -q --break-system-packages -r "$S/api/requirements.txt" 2>&1); rc=$?
c "pip install -r api/requirements.txt (rc $rc)" '[ $rc = 0 ] || { echo "$out" | tail -5; false; }'
c "raspap-api can import the modules" 'su -s /bin/sh raspap-api -c "python3 -c \"import fastapi, uvicorn, dotenv, psutil\""'

echo "== files with the modes of a device"
mkdir -p /etc/wireguard /etc/openvpn/client
chmod 700 /etc/wireguard
echo "[Interface]" > /etc/wireguard/travel.conf
ln -sf /etc/wireguard/travel.conf /etc/wireguard/wg0.conf
echo "<key>SECRET</key>" > /etc/openvpn/client/Test_client.conf
chown www-data /etc/openvpn/client/Test_client.conf
chmod 600 /etc/openvpn/client/Test_client.conf
printf "use=web\nprotocol=dyndns2\nlogin=me\npassword=pw\nexample.org\n" > /etc/ddclient.conf
chmod 600 /etc/ddclient.conf
mkdir -p /etc/raspap-api-test
cp -r "$S/api/." /etc/raspap-api-test/
chown -R root:root /etc/raspap-api-test

start_api() {  # $1 = user
    pkill -f "uvicorn main:app" 2> /dev/null; sleep 1
    (cd /etc/raspap-api-test && su -s /bin/sh "$1" -c "RASPAP_API_KEY=testkey123 python3 -m uvicorn main:app --host 127.0.0.1 --port 18081" > /tmp/uv.log 2>&1 &)
    for _ in $(seq 1 30); do curl -s -o /dev/null http://127.0.0.1:18081/docs && return 0; sleep 1; done
    tail -5 /tmp/uv.log; return 1
}
g() { curl -s -o /tmp/body -w '%{http_code}' -H 'access_token: testkey123' "http://127.0.0.1:18081$1"; }

echo "== API as raspap-api"
c "uvicorn starts as raspap-api" 'start_api raspap-api'
c "the service runs as raspap-api" 'pgrep -u raspap-api -f uvicorn > /dev/null'
r=$(g /wireguard)
c "/wireguard: 200, empty values" '[ "$r" = 200 ] && python3 -c "import json; d = json.load(open(\"/tmp/body\")); assert d[\"client_config_names\"] == [] and d[\"client_config_active\"] == \"\""'
r=$(g /openvpn)
c "/openvpn without an active config: 200, the names" '[ "$r" = 200 ] && grep -q Test_client.conf /tmp/body'
r=$(g /openvpn/Test_client.conf)
c "/openvpn/{config}: 200, empty, no key" '[ "$r" = 200 ] && ! grep -q SECRET /tmp/body && python3 -c "import json; assert json.load(open(\"/tmp/body\"))[\"client_config\"] == []"'
r=$(g /ddns)
c "/ddns: 200, no password" '[ "$r" = 200 ] && ! grep -q "\"pw\"" /tmp/body'
r=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18081/wireguard)
c "no key: 403" '[ "$r" = 403 ]'
ln -sf /etc/openvpn/client/Test_client.conf /etc/openvpn/client/client.conf
r=$(g /openvpn)
c "/openvpn with an active config: the active name" '[ "$r" = 200 ] && grep -q "\"client_config_active\":\"Test_client.conf\"" /tmp/body'

echo "== the same code as root"
c "uvicorn starts as root" 'start_api root'
r=$(g /wireguard)
c "/wireguard as root: the configs" '[ "$r" = 200 ] && grep -q travel.conf /tmp/body'
pkill -f "uvicorn main:app" 2> /dev/null

echo "== uninstall"
sudo() { "$@"; }
systemctl() { :; }
_install_error() { echo "ERROR $*"; return 1; }
eval "$(sed -n '/sudo systemctl disable --now restapi.service/,/^    fi$/p' "$S/installers/uninstall.sh")"
unset -f sudo systemctl
c "uninstall removes the user" '! id raspap-api > /dev/null 2>&1'

finish
