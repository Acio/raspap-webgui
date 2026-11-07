#!/bin/bash
#
# The RestAPI as the system user raspap-api, with the modules of
# api/requirements.txt in the venv /etc/raspap/api/venv: the functions of the
# installer, the update of an older install, the key check, and the endpoints
# that can not read their files. Needs internet access (pip).

. /s/tests/fork/lib.sh

echo "== setup"
_install_status() { echo "STATUS $*"; [ "$1" = 0 ] || [ "$1" = 2 ]; }
_install_log() { :; }
sudo() { "$@"; }
systemctl() { :; }
raspap_dir=/etc/raspap
webroot_dir=/tmp/web
mkdir -p "$webroot_dir/installers" "$raspap_dir"
cp "$S/installers/restapi.service" "$webroot_dir/installers/"
cp -r "$S/api" "$raspap_dir/api"
chown -R root:root "$raspap_dir/api"
eval "$(sed -n '/^function _restapi_venv()/,/^}/p;/^function _restapi_user()/,/^}/p;/^function _restapi_unit()/,/^}/p;/^function _update_restapi()/,/^}/p' "$S/installers/common.sh")"

echo "== install: venv, user and unit"
out=$(_restapi_venv 2>&1); rc=$?
c "venv with the modules of requirements.txt (rc $rc)" '[ $rc = 0 ] || { echo "$out" | tail -5; false; }'
c "venv belongs to root, raspap-api can not change it" '[ "$(stat -c %U "$raspap_dir/api/venv/lib")" = root ]'
c "the system Python is not changed" '! python3 -c "import fastapi" 2> /dev/null && [ -z "$(ls /usr/local/lib/python3*/dist-packages 2> /dev/null)" ]'
_restapi_user
c "user raspap-api: system user, nologin, no home" 'id raspap-api > /dev/null && [ "$(getent passwd raspap-api | cut -d: -f6,7)" = "/nonexistent:/usr/sbin/nologin" ] && [ "$(id -u raspap-api)" -lt 1000 ] && [ ! -e /nonexistent ]'
c "raspap-api can not write in the venv" '! su -s /bin/sh raspap-api -c "touch $raspap_dir/api/venv/x" 2> /dev/null'
_restapi_user
c "second run: no error, one user" '[ "$(getent passwd raspap-api | wc -l)" = 1 ]'
_restapi_unit
c "unit: User=raspap-api, Python of the venv" 'grep -qx "User=raspap-api" /lib/systemd/system/restapi.service && grep -qx "ExecStart=/etc/raspap/api/venv/bin/python -m uvicorn main:app --host 0.0.0.0 --port 8081" /lib/systemd/system/restapi.service && [ "$(stat -c %U:%a /lib/systemd/system/restapi.service)" = root:644 ]'

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

# the ExecStart of the unit, as the given user
start_api() {
    pkill -f "uvicorn main:app" 2> /dev/null; sleep 1
    local cmd
    cmd=$(sed -n 's/^ExecStart=//p' /lib/systemd/system/restapi.service | sed 's/0\.0\.0\.0 --port 8081/127.0.0.1 --port 18081/')
    (cd "$raspap_dir/api" && su -s /bin/sh "$1" -c "RASPAP_API_KEY=testkey123 $cmd" > /tmp/uv.log 2>&1 &)
    for _ in $(seq 1 30); do curl -s -o /dev/null http://127.0.0.1:18081/docs && return 0; sleep 1; done
    tail -5 /tmp/uv.log; return 1
}
g() { curl -s -o /tmp/body -w '%{http_code}' -H 'access_token: testkey123' "http://127.0.0.1:18081$1"; }

echo "== API as raspap-api, from the venv"
c "uvicorn starts as raspap-api" 'start_api raspap-api'
c "the service runs as raspap-api with the Python of the venv" 'pgrep -u raspap-api -f "venv/bin/python -m uvicorn" > /dev/null'
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
c "uvicorn from the venv starts as root" 'start_api root'
r=$(g /wireguard)
c "/wireguard as root: the configs" '[ "$r" = 200 ] && grep -q travel.conf /tmp/body'
pkill -f "uvicorn main:app" 2> /dev/null

echo "== update of an older install (unit with User=pi, system Python)"
_restapi_key() { :; }
_restapi_env_access() { :; }
rm -rf "$raspap_dir/api/venv"
printf '[Service]\nUser=pi\nExecStart=/usr/bin/python3 -m uvicorn main:app --host 0.0.0.0 --port 8081\n' > /lib/systemd/system/restapi.service
out=$(_update_restapi 2>&1); rc=$?
c "update: venv made, unit replaced (rc $rc)" '[ $rc = 0 ] && [ -x "$raspap_dir/api/venv/bin/python" ] && grep -qx "User=raspap-api" /lib/systemd/system/restapi.service && grep -q "venv/bin/python" /lib/systemd/system/restapi.service'
rm -rf "$raspap_dir/api/venv"
printf '[Service]\nUser=pi\nExecStart=/usr/bin/python3 -m uvicorn main:app --host 0.0.0.0 --port 8081\n' > /lib/systemd/system/restapi.service
cp "$raspap_dir/api/requirements.txt" /tmp/req.ok
echo "no-such-package-raspap==0.0.0" >> "$raspap_dir/api/requirements.txt"
out=$(_update_restapi 2>&1); rc=$?
cp /tmp/req.ok "$raspap_dir/api/requirements.txt"
c "update with a failed pip install: warning, old unit unchanged" 'echo "$out" | grep -q "STATUS 2" && grep -qx "User=pi" /lib/systemd/system/restapi.service'
unset -f sudo systemctl

echo "== uninstall"
sudo() { "$@"; }
systemctl() { :; }
_install_error() { echo "ERROR $*"; return 1; }
eval "$(sed -n '/sudo systemctl disable --now restapi.service/,/^    fi$/p' "$S/installers/uninstall.sh")"
unset -f sudo systemctl
c "uninstall removes the user" '! id raspap-api > /dev/null 2>&1'

finish
