# The hardened fork of RaspAP

This branch (`pi/hardened`) is an unofficial, hardened fork of [RaspAP](https://github.com/RaspAP/raspap-webgui). This file lists each change of the fork, so that we can do each change again when an upstream merge removes it.

## The rule for each change

Each change of the fork has these three parts:

1. One or more commits on `pi/hardened`. The commits are not squashed, so `git show <commit>` shows the change again.
2. A test in `tests/fork/suites/` that fails when the change is lost. Some old changes have no test yet (see "Changes without a test").
3. A row in the table below.

After each upstream merge, run `tests/fork/run.sh`. A failed test shows a lost change: do the change again from its commit.

## The changes

| Area | What the fork does | Commits | Test suite |
|---|---|---|---|
| Root scripts | `configport.sh`, `configauth.sh`, `servicestart.sh`, `debuglog.sh` and `toggle-routing.sh` check their arguments. The sudo rule of the updater allows only the web update. | `a7415111` | smallbugs, update |
| Plugin data | The bundled plugins keep their data in the private cache directory. | `bd08f907` | none |
| Config files | `raspap-config-file.sh` installs the hostapd, dhcpcd and dnsmasq files from stdin, with an option filter. dnsmasq files get only the options of the web interface (an allowlist), and `custom.txt` only hosts lines. hostapd files are root:www-data 640. | `cf0d7c68`, `0d51f2db`, `5cc26041` | smallbugs, hardening, adblock |
| Ad blocking | `update_blocklist.sh` takes only a list name. The URL and the target file come from the root-owned `/etc/raspap/adblock/blocklists.json`. The script keeps only blocking lines, because dnsmasq reads `domains.txt` as its configuration. An update filters the installed lists again (`update_blocklist.sh clean`). | `5cc26041` | adblock |
| VPN files | `raspap-vpn-file.sh` installs, reads and removes the WireGuard and OpenVPN files. | `0d402c3b` | static (sudo commands) |
| WiFi client | `raspap-wifi.sh` runs wpa_cli, wpa_supplicant and iw with checked arguments. | `321b4a59` | smallbugs (sudo rules) |
| Network tools and logs | `raspap-net.sh` and `raspap-logs.sh` run ip, iw, nmap and wvdial, and read and clear the logs. `clearlog.php` clears only the 3 logs. | `a611aef5` | smallbugs |
| sudo rules | Rules without a caller are removed, reboot only without arguments, no rule to move or touch `.env`. | `a7415111`, `a611aef5`, `0d51f2db` | static, smallbugs, hardening |
| RestAPI | The service runs as the system user `raspap-api`, from the root-owned venv `/etc/raspap/api/venv`, with systemd hardening. An update moves an older install. A root helper writes the key. | `25550589`, `da85ccd4`, `0d51f2db` | restapi, hardening |
| Updates | The update installs only the latest release of this fork, and saves the web root first. It keeps the plugins and their JavaScript, and writes `defaults.json` also with `fs.protected_regular=2`. An explicit `--branch` needs no release. The release tag is read also from minified JSON. The installer parts and the clone are in private temporary files, and the web root belongs to root until the last step. | `e0843270`, `87aa3791`, `5651c90a`, `32c0834e`, `b173d3d5`, `cfb85a95`, `f8dfc279` | update |
| Firewall plugin | The bundled Firewall plugin applies its rules with `raspap-firewall.sh` in own chains. An update replaces billz/Firewall. | `1a84ccbe`, `613ae46f`, `0d51f2db` | firewall, plugins, hardening |
| Plugin installs | The browser sends only the plugin name. The source comes from `config/plugins.json`. | `12fe5392` | plugins |
| Plugin helper | `plugin_helper.sh` refuses protected paths and unsafe sudo rules. | `e95ec97c` | plugins |
| Units | The units of RaspAP belong to root. The network monitor runs without root. | `0d51f2db` | hardening |
| Downloads | isoquery and mkcert have a SHA256 pin. | `0d51f2db` | hardening |
| Security headers | Each PHP page and ajax answer sends `X-Frame-Options: DENY`, a CSP against frames, `nosniff`, `Referrer-Policy: same-origin` and `Cache-Control: no-store` (`includes/session.php`). | `c06a668d` | hardening |
| Idle timeout | The server ends a session after `RASPI_SESSION_TIMEOUT` seconds without a page. A page goes to the login, an ajax request gets 401 and `session.js` shows the expired window. `login()` resets the idle time. | `c06a668d` | hardening |
| Error page | All users see a reference of the log line. Only the admin user sees the message and the trace (escaped). No X-Debug headers. `login()` saves the role. Fatal errors also get the page. | `c06a668d` | hardening |
| Web libraries | jQuery 3.7.1, DataTables 1.13.11 and Chart.js 2.9.4 in `dist/`. `package.json` lists the libraries in `dist/`, without a build. | `cc338d4c`, `cf3a041c` | static |
| Tests and CI | `tests/fork`, Fork CI, the release check and Dependabot. | `15c79397`, `e46e0754` | all |
| README | The fork notice and how to install the fork. | `7e66a338`, `72dd5875` | none |
| Version | `RASPI_VERSION` has 4 numbers: the upstream version and the fork release, for example `3.5.9.3`. | `e0843270` | update |

RaspAP itself has these changes now: the RestAPI key (#2233), the private OpenVPN and login files (#2235), and the small bug fixes (#2243).

## Changes without a test

These changes have no own test yet. Examine them by hand after an upstream merge:

- The plugin data in the private cache directory (`bd08f907`).
- The option filters of `raspap-config-file.sh` for hostapd and dhcpcd, and the checks of `raspap-vpn-file.sh`, `raspap-wifi.sh`, `raspap-net.sh` and `raspap-logs.sh`.
- The systemd options of `restapi.service` and `raspap-network-activity@.service`. The test container has no systemd, so test them on a device.

## Settings that are not in git

These settings are on GitHub. A merge does not change them, but a new fork or a new repository needs them again:

- The default branch of the fork is `pi/hardened`.
- The 5 upstream workflows (`codeql-analysis`, `codesee-arch-diagram`, `release`, `stale`, `sync-locales`) are disabled.
- Dependabot alerts and security updates are on.

## Merge an upstream release

1. Download the upstream changes: `git fetch upstream`.
2. Merge into `pi/hardened`: `git merge --no-ff upstream/master` (or the release tag).
3. Resolve the conflicts with these rules:
   - `installers/raspap.sudoers`: keep the fork version. For each new upstream rule, decide: a helper, a rule with exact arguments, or no rule.
   - Code that the fork replaced with a helper: keep the fork side, and put the upstream fix into the helper.
   - `config/config.php` (`RASPI_API_ENDPOINT`), `installers/raspbian.sh` (`repo=`) and `includes/defaults.php` (`RASPI_VERSION`): keep the fork values.
   - `yarn.lock` and `gulpfile.js` stay removed. When upstream changes a library in `dist/`, change its version in `package.json`.
   - `config/plugins.json`: compare it with the upstream plugin list, and change it by hand.
4. Look for new files in `.github/workflows/`. GitHub enables a new workflow file. Disable it on the fork (`gh workflow disable`) if we do not want it.
5. Run `tests/fork/run.sh`. Do each lost change again from its commit.
6. Set `RASPI_VERSION` to the upstream version with a 4th number, for example `3.6.0.1`.

## Make a release

1. Push to `pi/hardened` and wait for Fork CI.
2. Test the change on a device: `raspbian.sh --update --yes --check 0 --repo Acio/raspap-webgui --branch pi/hardened --path /var/www/html`, with a backup first.
3. Increase `RASPI_VERSION` in `includes/defaults.php`, push, and wait for Fork CI.
4. Create the GitHub release: the tag is `RASPI_VERSION`, the target is `pi/hardened`, not a pre-release, and marked as latest.
5. The release check examines the release. The update button of the devices then offers it.
