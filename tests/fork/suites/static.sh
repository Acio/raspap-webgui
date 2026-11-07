#!/bin/bash
#
# Static checks: syntax, shellcheck, sudoers, JSON, helper installs, and the
# fixed sudo commands of the PHP code against the sudo rules.

. /s/tests/fork/lib.sh
cd "$S" || exit 1

echo "== syntax"
out=$(find . -name '*.php' -not -path './dist/*' -not -path './vendor/*' -not -path './node_modules/*' -print0 |
    xargs -0 -n 1 php -l 2>&1 | grep -v '^No syntax errors' || true)
c "php -l on all PHP files" '[ -z "$out" ] || { echo "$out" | head -20; false; }'
out=$(for f in installers/*.sh tests/fork/*.sh tests/fork/suites/*.sh; do bash -n "$f" 2>&1; done)
c "bash -n on all shell scripts" '[ -z "$out" ] || { echo "$out"; false; }'

echo "== shellcheck (errors) on the root helpers"
helpers=()
for h in $(grep -oE '/usr/local/sbin/raspap-[a-z-]+\.sh' installers/raspap.sudoers plugins-available/*/manifest.json | sed 's/.*raspap-//' | sort -u); do
    [ -f "installers/$h" ] && helpers+=("installers/$h")
done
helpers+=(installers/plugin_helper.sh installers/raspap-iptables-save.sh installers/wg-killswitch.sh installers/wg-forward.sh)
c "shellcheck -S error on ${#helpers[@]} helpers" 'shellcheck -S error "${helpers[@]}"'

echo "== sudoers and JSON"
c "visudo accepts raspap.sudoers" 'visudo -cqf installers/raspap.sudoers'
for f in plugins-available/*/manifest.json; do
    manifest_sudoers "$f" > /tmp/plugin.sudoers
    c "visudo accepts the sudo rules of $f" 'visudo -cqf /tmp/plugin.sudoers'
done
out=$(for f in config/*.json plugins-available/*/manifest.json; do
    php -r 'json_decode(file_get_contents($argv[1])); exit(json_last_error() ? 1 : 0);' -- "$f" || echo "$f"
done)
c "all JSON files are valid" '[ -z "$out" ] || { echo "$out"; false; }'
c "no conflict markers" '! grep -rIlE "^(<<<<<<< |>>>>>>> )" --include=*.php --include=*.sh --include=*.js --include=*.json --include=*.sudoers . | grep -v -E "^./(dist|vendor|node_modules)/"'

echo "== each helper of the sudo rules has a source and an install line"
for h in $(grep -oE '/usr/local/sbin/raspap-[a-z-]+\.sh' installers/raspap.sudoers plugins-available/*/manifest.json | sed 's/^[^:]*://' | sort -u); do
    src="${h#/usr/local/sbin/raspap-}"
    [ "$src" = ts-optimize.sh ] && src="../plugins-available/Tailscale/config/ts-optimize.sh"
    c "$h" '[ -f "installers/$src" ] && grep -q "$h" installers/common.sh'
done

echo "== the fixed sudo commands of the PHP code are allowed for www-data"
setup_sudoers
manifest_sudoers plugins-available/Firewall/manifest.json > /etc/sudoers.d/090_Firewall
chmod 440 /etc/sudoers.d/090_Firewall
# the strings end before a variable, so some are only the start of a command:
# these are left out, and a full example is added for each
grep -rhoE "(exec|shell_exec|system|passthru)\((\"|')sudo [^\"'\$]*(\"|')" --include=*.php . |
    grep -v -E '^\./(dist|vendor)/' |
    sed -E "s/^[a-z_]+\(.sudo //; s/.$//; s/ *$//" | sort -u |
    grep -v -x -E '|/bin/systemctl (start|stop)|rm|touch|systemctl stop|mv /tmp/.env|/usr/local/sbin/raspap-net.sh link|/usr/local/sbin/raspap-vnstat.sh add' > /tmp/cmds.txt
printf '%s\n' '/bin/systemctl stop raspap-network-activity@*.service' '/usr/local/sbin/raspap-api-key.sh set' \
    '/usr/local/sbin/raspap-net.sh link wlan0 up' '/usr/local/sbin/raspap-vnstat.sh add wlan0' \
    '/usr/local/sbin/raspap-firewall.sh apply' '/usr/local/sbin/raspap-firewall.sh vpn-hosts' >> /tmp/cmds.txt
refused=""
while IFS= read -r cmd; do
    bin=${cmd%% *}
    case $bin in /*) p=$bin ;; *) p=/usr/bin/$bin ;; esac
    stub_programs "$p"
    eval "sudo -u www-data sudo -n -l $cmd" > /dev/null 2>&1 || refused="$refused
  $cmd"
done < /tmp/cmds.txt
c "$(wc -l < /tmp/cmds.txt) commands allowed" '[ -z "$refused" ] || { echo "refused:$refused"; false; }'

echo "== dist/ has the library versions of package.json"
# package|file|text before the version in the first lines of the file
libs=(
    "jquery|dist/jquery/jquery.min.js|jQuery v"
    "datatables.net|dist/datatables/jquery.dataTables.min.js|DataTables "
    "chart.js|dist/chart.js/Chart.min.js|Chart.js v"
    "bootstrap|dist/bootstrap/js/bootstrap.bundle.min.js|Bootstrap v"
    "@fortawesome/fontawesome-free|dist/font-awesome/css/all.min.css|Font Awesome Free "
    "huebee|dist/huebee/huebee.pkgd.min.js|Huebee PACKAGED v"
    "jquery-mask-plugin|dist/jquery-mask/jquery.mask.min.js|jQuery Mask Plugin v"
    "jquery.easing|dist/jquery-easing/jquery.easing.js|jQuery Easing v"
)
pkgver() { php -r '$d = json_decode(file_get_contents("package.json"), true); echo $d["dependencies"][$argv[1]] ?? "";' -- "$1"; }
for l in "${libs[@]}"; do
    IFS='|' read -r pkg file prefix <<< "$l"
    want=$(pkgver "$pkg")
    have=$(head -c 600 "$file" | tr '\n' ' ' | grep -oF "$prefix$want" | head -1)
    c "$pkg $want in $file" '[ -n "$want" ] && [ "$have" = "$prefix$want" ]'
done
c "datatables.net-bs4 has the version of datatables.net" '[ "$(pkgver datatables.net-bs4)" = "$(pkgver datatables.net)" ]'
c "no npm build files (dist/ is updated by hand)" '[ ! -e yarn.lock ] && [ ! -e gulpfile.js ] && [ ! -e package-lock.json ]'

finish
