#!/bin/bash
#
# RaspAP installation functions
# Author: @billz <billzimmerman@gmail.com>
# Author URI: https://github.com/billz/
# License: GNU General Public License v3.0
# License URI: https://github.com/raspap/raspap-webgui/blob/master/LICENSE

# You are not obligated to bundle the LICENSE file with your RaspAP projects as long
# as you leave these references intact in the header comments of your source files.

# Exit on error
set -o errexit
# Exit on error inside functions
set -o errtrace
# Turn on traces, disabled by default
# set -o xtrace

# Set defaults
readonly raspap_dir="/etc/raspap"
readonly raspap_user="www-data"
readonly raspap_sudoers="/etc/sudoers.d/090_raspap"
readonly raspap_default="/etc/dnsmasq.d/090_raspap.conf"
readonly raspap_wlan0="/etc/dnsmasq.d/090_wlan0.conf"
readonly raspap_adblock="/etc/dnsmasq.d/090_adblock.conf"
readonly raspap_sysctl="/etc/sysctl.d/90_raspap.conf"
readonly raspap_network="$raspap_dir/networking/"
readonly raspap_router="/etc/lighttpd/conf-available/50-raspap-router.conf"
readonly rulesv4="/etc/iptables/rules.v4"

# Use ssh if $ssh is set, otherwise https
if [ "$ssh" == 1 ]; then
    git_source_url="git@github.com:$repo"
else
    git_source_url="https://github.com/$repo"
fi
webroot_dir="/var/www/html"

# NOTE: all the below functions are overloadable for system-specific installs
function _install_raspap() {
    _display_welcome
    _config_installation
    _update_system_packages
    _manage_systemd_services
    _install_dependencies
    _enable_php_lighttpd
    _create_raspap_directories
    _check_for_old_configs
    _optimize_php
    _download_latest_files
    _create_hostapd_scripts
    _install_raspap_hostapd
    _create_plugin_scripts
    _create_lighttpd_scripts
    _install_lighttpd_configs
    _default_configuration
    _configure_networking
    _prompt_configure_tcp_bbr
    _prompt_install_features
    _install_extra_features
    _patch_system_files
    # last: until here, the installer installs root files from the web root,
    # so www-data must not own it yet
    _change_file_ownership
    _install_complete
}

# Performs a minimal update of an existing installation to the latest release version.
# The user is not prompted to install new RaspAP components.
# The -y, --yes and -p, --path switches may be used for an unattended update.
function _update_raspap() {
    _detach_from_php_fpm
    _display_welcome
    _config_installation
    _update_system_packages
    _install_dependencies
    _check_for_old_configs
    _download_latest_files
    _secure_raspap_directories
    _secure_openvpn_client_files
    _patch_system_files
    _create_hostapd_scripts
    _update_openvpn_scripts
    _update_wireguard
    _update_restapi
    _enable_network_activity_monitor
    _create_plugin_scripts
    _migrate_firewall_plugin
    _migrate_ntpserver_plugin
    # last: until here, the update installs root files from the web root, so
    # www-data must not own it yet
    _change_file_ownership
    _install_complete
}

# When an update is started from the web UI, the installer runs inside the
# php-fpm service cgroup. Restarting php-fpm during the update (directly or
# via apt) would kill the installer along with it, so relaunch the update as
# a transient systemd unit and exit
function _detach_from_php_fpm() {
    local fpm_unit
    fpm_unit=$(grep -oE 'php[0-9.]*-fpm\.service' /proc/self/cgroup 2>/dev/null) || return 0
    if ! command -v systemd-run > /dev/null || [ ! -f "$0" ]; then
        return 0
    fi
    # the update log must be written to the same /tmp that php-fpm reads
    if [ "$(systemctl show -p PrivateTmp --value "$fpm_unit")" != "no" ]; then
        return 0
    fi
    local args=(--update --yes --check 0 --repo "$repo" --branch "$branch")
    if [ -n "$path" ]; then
        args+=(--path "$path")
    fi
    echo "Relaunching update outside of $fpm_unit"
    sudo systemd-run --unit=raspap-update --collect --quiet "$0" "${args[@]}" || _install_status 1 "Unable to start raspap-update.service"
    exit 0
}

# Prompts user to set installation options
function _config_installation() {
    if [ "$upgrade" == 1 ]; then
        opt=(Upgrade Upgrading upgrade)
    elif [ "$update" == 1 ]; then
        opt=(Update Updating update)
    else
        opt=(Install Installing installation)
    fi
    _install_log "Configure ${opt[2]}"
    _get_linux_distro
    echo "Detected OS: ${DESC} ${LONG_BIT}-bit"
    echo "Using GitHub repository: ${repo} ${branch} branch"
    echo "Configuration directory: ${raspap_dir}"

    if [ -n "$path" ]; then
        echo "Setting install path to ${path}"
        webroot_dir=$path
    fi
    echo -n "Installation directory: ${webroot_dir}? [Y/n]: "
    if [ "$assume_yes" == 0 ]; then
        read answer < /dev/tty
        if [ "$answer" != "${answer#[Nn]}" ]; then
            read -e -p < /dev/tty "Enter alternate install directory: " -i "/var/www/html" webroot_dir
        fi
    else
        echo -e
    fi
    echo "${opt[1]} lighttpd directory: ${webroot_dir}"
    if [ "$upgrade" == 1 ] || [ "$update" == 1 ]; then
        echo "This will ${opt[2]} your existing install to version ${RASPAP_RELEASE}"
        echo "Your configuration will NOT be changed"
    fi
    echo -n "Complete ${opt[2]} with these values? [Y/n]: "
    if [ "$assume_yes" == 0 ]; then
        read answer < /dev/tty
        if [ "$answer" != "${answer#[Nn]}" ]; then
            echo "Installation aborted."
            exit 0
        fi
    else
        echo -e
    fi
}

# Determines host Linux distribution details
function _get_linux_distro() {
    if type lsb_release >/dev/null 2>&1; then # linuxbase.org
        OS=$(lsb_release -si)
        RELEASE=$(lsb_release -sr)
        CODENAME=$(lsb_release -sc)
        DESC=$(lsb_release -sd)
        LONG_BIT=$(getconf LONG_BIT)
    elif [ -f /etc/os-release ]; then # freedesktop.org
        . /etc/os-release
        OS=$ID
        RELEASE=$VERSION_ID
        CODENAME=$VERSION_CODENAME
        DESC=$PRETTY_NAME
    else
        _install_status 1 "Unsupported Linux distribution"
        exit 0
    fi
}

# Sets php package option based on Linux version, abort if unsupported distro
function _set_php_package() {
    case $RELEASE in
        13|2025.*) # Debian 13 trixie, Kali Linux 2025
            php_package="php8.4-fpm"
            phpiniconf="/etc/php/8.4/fpm/php.ini" ;;
        23.05|12*) # Debian 12 & Armbian 23.05
            php_package="php8.2-cgi"
            phpiniconf="/etc/php/8.2/cgi/php.ini" ;;
        23.04) # Ubuntu Server 23.04
            php_package="php8.1-cgi"
            phpiniconf="/etc/php/8.1/cgi/php.ini" ;;
        22.04|20.04|18.04|19.10|11*) # Previous Ubuntu Server, Debian & Armbian distros
            php_package="php7.4-cgi"
            phpiniconf="/etc/php/7.4/cgi/php.ini" ;;
        10*|11*)
            php_package="php7.3-cgi"
            phpiniconf="/etc/php/7.3/cgi/php.ini" ;;
        9*)
            php_package="php7.0-cgi"
            phpiniconf="/etc/php/7.0/cgi/php.ini" ;;
        8)
            _install_status 1 "${DESC} and php5 are not supported. Please upgrade."
            exit 1 ;;
        *)
            _install_status 1 "${DESC} is unsupported. Please install on a supported distro."
            exit 1 ;;
    esac
}

# Prompts the user to stop & disable Debian's systemd-networkd services.
# It isn't possible to mix Debian networking with dhcpcd.
# On Ubuntu 20.04 / Armbian 22, the systemd-resolved service uses port 53
# by default which prevents dnsmasq from starting.
function _manage_systemd_services() { 
    _install_log "Checking for systemd network services"

    _check_notify_ubuntu

    services=( "systemd-networkd" "systemd-resolved" )
    for svc in "${services[@]}"; do
        # Prompt to disable systemd service
        if systemctl is-active --quiet "$svc".service; then
            echo -n "Stop and disable ${svc} service? [Y/n]: "
            if [ "$assume_yes" == 0 ]; then
                read answer < /dev/tty
                if [ "$answer" != "${answer#[Nn]}" ]; then
                    echo -e
                else
                    sudo systemctl stop "$svc".service || _install_status 1 "Unable to stop ${svc}.service"
                    sudo systemctl disable "$svc".service || _install_status 1 "Unable to disable ${svc}.service"
                fi
            else
                sudo systemctl stop "$svc".service || _install_status 1 "Unable to stop ${svc}.service"
                sudo systemctl disable "$svc".service || _install_status 1 "Unable to disable ${svc}.service"
            fi
        else
            echo "${svc}.service is not running (ok)"
        fi
    done
    _install_status 0
}

# Notifies Ubuntu users of pre-install requirements
function _check_notify_ubuntu() {
    if [ ${OS,,} = "ubuntu" ]; then
        _install_status 2 "Ubuntu Server requires manual pre- and post-install steps. See https://docs.raspap.com/manual/"
        echo -n "Proceed with installation? [Y/n]: "
        read answer < /dev/tty
        if [ "$answer" != "${answer#[Nn]}" ]; then
            echo "Installation aborted."
            exit 0
        else
            _install_status 0
        fi
    fi
}

# Runs a system software update to make sure we're using all fresh packages
function _install_dependencies() {
    _install_log "Installing required packages"
    _set_php_package

    # OS-specific packages
    if [ "$php_package" = "php7.4-cgi" ] && [ ${OS,,} = "ubuntu" ] && [[ ${RELEASE} =~ ^(22.04|20.04|18.04|19.10|11) ]]; then
        echo "Adding apt-repository ppa:ondrej/php"
        sudo apt-get install -y software-properties-common || _install_status 1 "Unable to install dependency"
        sudo add-apt-repository $apt_option ppa:ondrej/php || _install_status 1 "Unable to add-apt-repository ppa:ondrej/php"
    else
        echo "${php_package} will be installed from the main deb sources list"
    fi
    if [ ${OS,,} = "debian" ] || [ ${OS,,} = "ubuntu" ] || [ ${OS,,} = "kali" ]; then
        dhcpcd_package="dhcpcd5"
        iw_package="iw"
        rsync_package="rsync"
        echo "${dhcpcd_package}, ${iw_package} and ${rsync_package} will be installed from the main deb sources list"
    fi
    if [ ${OS,,} = "raspbian" ] && [[ ${RELEASE} =~ ^(12) ]]; then
        dhcpcd_package="dhcpcd dhcpcd-base"
        echo "${dhcpcd_package} will be installed from the main deb sources list"
    fi
    if [ ${OS,,} = "armbian" ]; then
        ifconfig_package="net-tools"
        echo "${ifconfig_package} will be installed from the main deb sources list"

        # Manually install isoquery
        _install_log "Installing isoquery from the Debian package repository"
        isoquery_deb="https://ftp.debian.org/debian/pool/main/i/isoquery"
        # the SHA256 of the Debian (trixie) package index
        if [ "$LONG_BIT" = "64" ]; then
            isoquery_pkg="isoquery_3.3.4-1+b1_arm64.deb"
            isoquery_sha256="d2f10836ef22134b0c648c6886d991cfda4baeb82b155f763e1afc01fff49adf"
        else
            isoquery_pkg="isoquery_3.3.4-1_armhf.deb"
            isoquery_sha256="eeec37532fac8f478c271de9423ea71ac95f8a39849903b3c33b5fd479d6ed71"
        fi
        echo "isoquery ARM ${LONG_BIT}-bit package selected"
        local isoquery_tmp
        isoquery_tmp=$(mktemp -d) || _install_status 1 "Unable to create a temporary directory"
        wget $isoquery_deb/$isoquery_pkg -q --show-progress --progress=bar:force -P "$isoquery_tmp" || _install_status 1 "Failed to download isoquery"
        echo "$isoquery_sha256  $isoquery_tmp/$isoquery_pkg" | sha256sum -c --quiet - || _install_status 1 "The isoquery package has a wrong SHA256"
        sudo dpkg -x "$isoquery_tmp/$isoquery_pkg" "$isoquery_tmp/x" || _install_status 1 "Failed to extract isoquery"
        sudo install -o root -g root -m 755 "$isoquery_tmp/x/usr/bin/isoquery" /usr/local/bin/isoquery || _install_status 1 "Failed to copy isoquery binary"
        sudo rm -rf "$isoquery_tmp"
    fi

    network_tools="curl dnsutils nmap"
    echo "${network_tools} will be installed from the main deb sources list"

    # Set dconf-set-selections
    echo iptables-persistent iptables-persistent/autosave_v4 boolean true | sudo debconf-set-selections
    echo iptables-persistent iptables-persistent/autosave_v6 boolean true | sudo debconf-set-selections
    # iso-codes is only recommended by isoquery and not installed where APT::Install-Recommends is 0 (e.g. Armbian)
    sudo apt-get install -y lighttpd git hostapd dnsmasq iptables-persistent $php_package $dhcpcd_package $iw_package $rsync_package $network_tools $ifconfig_package vnstat qrencode jq isoquery iso-codes || _install_status 1 "Unable to install dependencies"

    if [[ "$php_package" == *"-fpm" ]]; then
        _install_log "Enabling lighttpd fastcgi-php-fpm module for $php_package"
        fpm_output=$(sudo lighty-enable-mod fastcgi-php-fpm 2>&1)
        fpm_status=$?
        echo "$fpm_output"
        if [ $fpm_status -ne 0 ] && [[ "$fpm_output" != *"already enabled"* ]]; then
            _install_status 1 "Unable to enable fastcgi-php-fpm module"
        fi
        sudo systemctl restart $php_package.service || _install_status 1 "Unable to restart $php_package.service"
    fi
    _install_status 0
}

# Enables PHP for lighttpd and restarts service for settings to take effect
function _enable_php_lighttpd() {
    _install_log "Enabling PHP for lighttpd"
    if [[ "$php_package" == *"-fpm" ]]; then
        sudo lighttpd-enable-mod fastcgi-php-fpm
    else
        sudo lighttpd-enable-mod fastcgi-php
    fi
    sudo service lighttpd force-reload
    sudo systemctl restart lighttpd.service || _install_status 1 "Unable to restart lighttpd"
}

# Verifies existence and permissions of RaspAP directory
function _create_raspap_directories() {
    _install_log "Creating RaspAP directories"
    if [ -d "$raspap_dir" ]; then
        sudo mv $raspap_dir "$raspap_dir.`date +%F-%R`" || _install_status 1 "Unable to move old '$raspap_dir' out of the way"
    fi
    sudo mkdir -p "$raspap_dir" || _install_status 1 "Unable to create directory '$raspap_dir'"

    # Create a directory for existing file backups.
    sudo mkdir -p "$raspap_dir/backups"

    # Create a directory to store networking configs
    echo "Creating $raspap_dir/networking"
    sudo mkdir -p "$raspap_dir/networking"
    echo "Changing file ownership of $raspap_dir/backups"
    sudo chown -R $raspap_user:$raspap_user "$raspap_dir/backups" || _install_status 1 "Unable to change file ownership for '$raspap_dir/backups'"
    _secure_raspap_directories
}

# www-data can run the scripts in the subdirectories of $raspap_dir with sudo.
# The owner of a directory can rename or delete its entries, so only root may
# own these directories and $raspap_dir. The web interface keeps its own
# files in $raspap_dir and its networking directory, so www-data may create
# files there, and the sticky bit keeps it from renaming or deleting the
# entries of root. All script directories are created, also for features
# that are not installed, so that www-data cannot create one of them
function _secure_raspap_directories() {
    echo "Securing the script directories of $raspap_dir"
    local dir
    for dir in hostapd lighttpd openvpn system adblock plugins; do
        sudo mkdir -p "$raspap_dir/$dir" || _install_status 1 "Unable to create directory '$raspap_dir/$dir'"
        sudo chown root:root "$raspap_dir/$dir" || _install_status 1 "Unable to change owner of '$raspap_dir/$dir'"
        sudo chmod 755 "$raspap_dir/$dir" || _install_status 1 "Unable to change permissions of '$raspap_dir/$dir'"
        sudo find "$raspap_dir/$dir" -mindepth 1 -exec chown root:root {} + -exec chmod go-w {} + || _install_status 1 "Unable to change owner of the files in '$raspap_dir/$dir'"
    done
    for dir in "$raspap_dir" "$raspap_dir/networking"; do
        sudo chown root:$raspap_user "$dir" || _install_status 1 "Unable to change owner of '$dir'"
        sudo chmod 1775 "$dir" || _install_status 1 "Unable to change permissions of '$dir'"
    done
    # the REST API service runs the code of this directory
    if [ -d "$raspap_dir/api" ]; then
        sudo chown -R root:root "$raspap_dir/api" || _install_status 1 "Unable to change owner of '$raspap_dir/api'"
    fi

    # Older versions installed these scripts in the networking directory,
    # which www-data can change
    if [ -e "$raspap_dir/networking/toggle-routing.sh" ]; then
        echo "Moving toggle-routing.sh to /usr/local/sbin"
        sudo install -o root -g root -m 755 "$webroot_dir/installers/toggle-routing.sh" /usr/local/sbin/raspap-toggle-routing.sh || _install_status 1 "Unable to install toggle-routing.sh script"
        sudo rm -f "$raspap_dir/networking/toggle-routing.sh"
    fi
    if [ -e "$raspap_dir/networking/usb-tethering.sh" ]; then
        echo "Moving usb-tethering.sh to /usr/local/sbin"
        sudo install -o root -g root -m 755 "$webroot_dir/installers/usb-tethering.sh" /usr/local/sbin/raspap-usb-tethering.sh || _install_status 1 "Unable to install usb-tethering.sh"
        sudo cp "$webroot_dir/installers/90-raspap-usb-tethering.rules" /etc/udev/rules.d/ || _install_status 1 "Unable to copy udev rules"
        sudo udevadm control --reload-rules || _install_status 1 "Unable to reload udev rules"
        sudo rm -f "$raspap_dir/networking/usb-tethering.sh"
    fi
    # the Tailscale plugin installed this script owned by www-data
    local ts_old="$raspap_dir/networking/ts-optimize.sh"
    local ts_new="/usr/local/sbin/raspap-ts-optimize.sh"
    if [ -e "$ts_old" ]; then
        echo "Moving ts-optimize.sh to /usr/local/sbin"
        sudo install -o root -g root -m 755 "$webroot_dir/plugins-available/Tailscale/config/ts-optimize.sh" "$ts_new" || _install_status 1 "Unable to install ts-optimize.sh"
        sudo rm -f "$ts_old"
    fi
    local file tmp
    for file in $(sudo grep -rlF "$ts_old" /etc/sudoers.d/ 2>/dev/null); do
        tmp=$(mktemp) || _install_status 1 "Unable to update $file"
        sudo sed "s|$ts_old|$ts_new|g" "$file" > "$tmp" || _install_status 1 "Unable to update $file"
        sudo visudo -cqf "$tmp" || _install_status 1 "Unable to update $file"
        sudo install -o root -g root -m 0440 "$tmp" "$file" || _install_status 1 "Unable to update $file"
        rm -f "$tmp"
    done
}

# Generate hostapd logging and service control scripts
function _create_hostapd_scripts() {
    _install_log "Creating hostapd logging & control scripts"
    sudo mkdir -p $raspap_dir/hostapd || _install_status 1 "Unable to create directory '$raspap_dir/hostapd'"

    # Copy service control shell scripts
    sudo cp "$webroot_dir/installers/"servicestart.sh "$raspap_dir/hostapd" || _install_status 1 "Unable to move service control scripts"
    # Change ownership and permissions of hostapd control scripts
    sudo chown -c root:root "$raspap_dir/hostapd/"*.sh || _install_status 1 "Unable change owner and/or group"
    sudo chmod 750 "$raspap_dir/hostapd/"*.sh || _install_status 1 "Unable to change file permissions"
    _install_status 0
}

# Generate plugin helper scripts
# Replaces a downloaded plugin with the bundled plugin of the hardened fork:
# a symlink to plugins-available, the sudo rules of the bundled manifest and
# its JavaScript. Only when the downloaded plugin is installed.
# Usage: _migrate_to_bundled_plugin <plugin name> <sudoers name> <JavaScript file>
function _migrate_to_bundled_plugin() {
    local name="$1" rules="/etc/sudoers.d/$2" js="$3"
    local old="$webroot_dir/plugins/$name"
    local new="$webroot_dir/plugins-available/$name"
    if [ ! -d "$new" ] || [ ! -d "$old" ] || [ -L "$old" ]; then
        return 1
    fi
    _install_log "Replacing the $name plugin with the plugin of the hardened fork"
    sudo rm -rf "$old" || _install_status 1 "Unable to remove the old $name plugin"
    sudo ln -s "$new" "$old" || _install_status 1 "Unable to install the $name plugin"
    sudo chown -h $raspap_user:$raspap_user "$old"

    # the sudo rules of the bundled manifest
    local tmp
    tmp=$(sudo mktemp /etc/sudoers.d/.plugin.XXXXXX) || _install_status 1 "Unable to create a temporary file"
    php -r 'echo implode(PHP_EOL, json_decode(file_get_contents($argv[1]), true)["sudoers"]).PHP_EOL;' -- "$new/manifest.json" |
        sudo tee "$tmp" > /dev/null || { sudo rm -f "$tmp"; _install_status 1 "Unable to write the $name sudo rules"; }
    sudo chmod 440 "$tmp"
    if sudo visudo -cqf "$tmp"; then
        sudo mv -f "$tmp" "$rules" || _install_status 1 "Unable to install the $name sudo rules"
    else
        sudo rm -f "$tmp"
        _install_status 1 "Invalid $name sudo rules"
    fi
    sudo mkdir -p "$webroot_dir/app/js/plugins"
    sudo install -o $raspap_user -g $raspap_user -m 644 "$new/templates/app/js/$js" "$webroot_dir/app/js/plugins/$js" ||
        _install_status 1 "Unable to install $js"
    return 0
}

# Replaces the Firewall plugin of billz/Firewall with the bundled Firewall
# plugin of the hardened fork. The old plugin ran scripts from /tmp as root and
# flushed all iptables rules. Only when the old plugin is installed.
function _migrate_firewall_plugin() {
    _migrate_to_bundled_plugin Firewall 090_Firewall Firewall.js || return 0
    # the rules of the old plugin move to the own chains of the helper
    sudo /usr/local/sbin/raspap-firewall.sh apply || _install_status 1 "Unable to apply the firewall rules"
    _install_status 0
}

# Replaces the NTP Server plugin of billz/NTPServer with the bundled plugin of
# the hardened fork. The old plugin copied /tmp/ntpdata to ntp.conf as root,
# and its sudo rules had wildcards. Only when the old plugin is installed.
function _migrate_ntpserver_plugin() {
    _migrate_to_bundled_plugin NTPServer 090_NTPServer NTPServer.js || return 0
    _install_status 0
}

function _create_plugin_scripts() {
    _install_log "Creating plugin helper scripts"
    sudo mkdir -p $raspap_dir/plugins || _install_status 1 "Unable to create directory '$raspap_dir/plugins'"

    # Copy plugin helper script
    sudo cp "$webroot_dir/installers/"plugin_helper.sh "$raspap_dir/plugins" || _install_status 1 "Unable to move plugin script"
    # Change ownership and permissions of plugin script
    sudo chown -c root:root "$raspap_dir/plugins/"*.sh || _install_status 1 "Unable change owner and/or group"
    sudo chmod 750 "$raspap_dir/plugins/"*.sh || _install_status 1 "Unable to change file permissions"
    _install_status 0
}

# Generate lighttpd service control scripts
function _create_lighttpd_scripts() {
    _install_log "Creating lighttpd control scripts"
    sudo mkdir -p $raspap_dir/lighttpd || _install_status 1 "Unable to create directory '$raspap_dir/lighttpd"

    # Copy service control shell scripts
    echo "Copying configport.sh to $raspap_dir/lighttpd"
    sudo cp "$webroot_dir/installers/"configport.sh "$raspap_dir/lighttpd" || _install_status 1 "Unable to move service control scripts"
    # Change ownership and permissions of lighttpd scripts
    echo "Changing file ownership"
    sudo chown -c root:root "$raspap_dir/lighttpd/"*.sh || _install_status 1 "Unable change owner and/or group"
    sudo chmod 750 "$raspap_dir/lighttpd/"*.sh || _install_status 1 "Unable to change file permissions"
    _install_status 0
}

# Copy extra config files required to configure lighttpd
function _install_lighttpd_configs() {
    _install_log "Copying lighttpd extra config files"

    # Copy config files
    echo "Copying 50-raspap-router.conf to /etc/lighttpd/conf-available"

    CONFSRC="$webroot_dir/config/50-raspap-router.conf"
    LTROOT=$(grep "server.document-root" /etc/lighttpd/lighttpd.conf | awk -F '=' '{print $2}' | tr -d " \"")

    # Compare values and get difference
    HTROOT=${webroot_dir/$LTROOT}

    # Remove trailing slash if present
    HTROOT=$(echo "$HTROOT" | sed -e 's/\/$//')

    # Substitute values
    local router_conf
    router_conf=$(mktemp) || _install_status 1 "Unable to create a temporary file"
    awk "{gsub(\"/REPLACE_ME\",\"$HTROOT\")}1" $CONFSRC > "$router_conf"

    # Copy into place
    sudo install -o root -g root -m 644 "$router_conf" /etc/lighttpd/conf-available/50-raspap-router.conf || _install_status 1 "Unable to copy lighttpd config file into place."
    rm -f "$router_conf"

    # Link into conf-enabled
    echo "Creating link to /etc/lighttpd/conf-enabled"
    if ! [ -L $raspap_router ]; then
        echo "Existing 50-raspap-router.conf found. Unlinking."
        sudo unlink "/etc/lighttpd/conf-enabled/50-raspap-router.conf"
    fi
    echo "Linking 50-raspap-router.conf to /etc/lighttpd/conf-enabled/"
    sudo ln -s "/etc/lighttpd/conf-available/50-raspap-router.conf" "/etc/lighttpd/conf-enabled/50-raspap-router.conf" || _install_status 1 "Unable to symlink lighttpd config file (this is normal if the link already exists)."
    sudo systemctl restart lighttpd.service || _install_status 1 "Unable to restart lighttpd"
    _install_status 0
}

function _prompt_install_features() {
    readonly features=(
      "Ad blocking:Install Ad blocking and enable list management:adblock_option:_install_adblock"
      "OpenVPN:Install OpenVPN and enable client configuration:ovpn_option:_install_openvpn"
      "RestAPI:Install and enable RestAPI:restapi_option:_install_restapi"
      "WireGuard:Install WireGuard and enable VPN tunnel configuration:wg_option:_install_wireguard"
      "VPN provider:Enable VPN provider client configuration:pv_option:_install_provider"
    )
    for feature in "${features[@]}"; do
      IFS=':' read -r -a feature_details <<< "$feature"
      _prompt_install_feature "${feature_details[@]}"
    done
}

# Prompt to install optional feature
function _prompt_install_feature() {
    local feature="$1"
    local prompt="$2"
    local opt="$3"
    local function="$4"
    _install_log "Configure $feature support"
    echo -n "$prompt? [Y/n]: "
    if [ "$assume_yes" == 0 ]; then
        read answer < /dev/tty
        if [ "$answer" != "${answer#[Nn]}" ]; then
            _install_status 0 "(Skipped)"
        else
            $function
        fi
    elif [ "$opt" == "pv_option" ]; then
        local opt_value=${!opt:-0}
        if [ "$opt_value" == 0 ]; then
            echo "(Skipped)"
        else
            local valid_ids=($(jq -r '.providers[].id' "$webroot_dir/config/vpn-providers.json"))
            local found=0
            for id in "${valid_ids[@]}"; do
                if [ "$id" == "$opt_value" ]; then
                    found=1
                    break
                fi
            done
            if [ $found == 1 ]; then
                echo -e
                $function
            else
                _install_status 1 "Invalid VPN provider ID $opt_value - (Skipped)"
            fi
        fi
    elif [ "${!opt}" == 1 ]; then
        echo -e
        $function
    else
        echo "(Skipped)"
    fi
}

# Installs the blocklist update script and its root-owned copy of the list of
# blocklists. The script reads the URLs from that copy, not from the web root.
# Also on an update: the script then filters the installed lists again.
function _install_blocklist_script() {
    sudo install -o root -g root -m 750 "$webroot_dir/installers/update_blocklist.sh" "$raspap_dir/adblock/update_blocklist.sh" ||
        _install_status 1 "Unable to install the blocklist update script"
    sudo install -o root -g root -m 644 "$webroot_dir/config/blocklists.json" "$raspap_dir/adblock/blocklists.json" ||
        _install_status 1 "Unable to install the list of blocklists"
}

# Download adblock lists and enable option
function _install_adblock() {
    _install_log "Creating ad blocking base configuration (Beta)"
    if [ ! -d "$raspap_dir/adblock" ]; then
        echo "Creating $raspap_dir/adblock"
        sudo mkdir -p "$raspap_dir/adblock"
    fi
    _install_blocklist_script
    # empty lists first, so that dnsmasq starts also when a download fails
    local list
    for list in hostnames.txt domains.txt; do
        if [ ! -f "$raspap_dir/adblock/$list" ]; then
            sudo install -o root -g "$raspap_user" -m 644 /dev/null "$raspap_dir/adblock/$list" || _install_status 1 "Unable to create $list"
        fi
    done
    # the default lists, downloaded and filtered by the update script itself
    echo "Fetching the default blocklists"
    sudo "$raspap_dir/adblock/update_blocklist.sh" "StevenBlack/hosts (default)" > /dev/null || _install_status 1 "Unable to download the default hostnames list"
    sudo "$raspap_dir/adblock/update_blocklist.sh" "oisd/big (default)" > /dev/null || _install_status 1 "Unable to download the default domains list"

    # Create 090_adblock.conf and write values to /etc/dnsmasq.d
    if [ ! -f "$raspap_adblock" ]; then
        echo "Adding 090_addblock.conf to /etc/dnsmasq.d"
        sudo touch "$raspap_adblock"
        echo "conf-file=$raspap_dir/adblock/domains.txt" | sudo tee -a "$raspap_adblock" > /dev/null || _install_status 1 "Unable to write to $raspap_adblock"
        echo "addn-hosts=$raspap_dir/adblock/hostnames.txt" | sudo tee -a "$raspap_adblock" > /dev/null || _install_status 1 "Unable to write to $raspap_adblock"
    fi

    # Remove dhcp-option=6 in dnsmasq.d/090_wlan0.conf to force local DNS resolution for DHCP clients
    echo "Enabling local DNS name resolution for DHCP clients"
    sudo sed -i '/dhcp-option=6/d' $raspap_wlan0 || _install_status 1 "Unable to modify $raspap_dnsmasq"

    echo "Enabling ad blocking management option"
    sudo sed -i "s/\('RASPI_ADBLOCK_ENABLED', \)false/\1true/g" "$webroot_dir/includes/config.php" || _install_status 1 "Unable to modify config.php"
    _install_status 0
}

# Install VPN provider client configuration
function _install_provider() {
    _install_log "Installing VPN provider support"
    json="$webroot_dir/config/"vpn-providers.json
    while IFS='|' read -r key value; do
        options["$key"]="$value"
    done< <(jq -r '.providers[] | "\(.id)|\(.name)|\(.bin_path)"' "$json")

    if [ -n "$pv_option" ]; then
        if [[ -n ${options[$pv_option]+abc} ]]; then
            answer="$pv_option"
        else
            echo "Invalid choice. The specified option does not exist."
            return 1
        fi
    else
        echo -e "Select an option from the list:"
        while true; do
            # display provider options
            for key in "${!options[@]}"; do
                echo "  $key) ${options[$key]%%|*}"
            done
            echo "  0) None"
            echo -n "Choose an option: "
            read answer < /dev/tty

            if [ "$answer" != "${answer#[0]}" ]; then
                _install_status 0 "(Skipped)"
                skip=true
                break
            elif [[ "$answer" =~ ^[0-9]+$ ]] && [[ -n ${options[$answer]+abc} ]]; then
                break
            else
                echo "Invalid choice. Select a valid option:"
            fi
        done
    fi
    if ! [ "$skip" ]; then
        selected="${options[$answer]}"
        echo "Configuring support for ${selected%%|*}"
        bin_path=${selected#*|}
        if ! grep -q "$bin_path" "$webroot_dir/installers/raspap.sudoers"; then
            echo "Adding $bin_path to raspap.sudoers"
            echo "www-data ALL=(ALL) NOPASSWD:$bin_path *" | sudo tee -a "$webroot_dir/installers/raspap.sudoers" > /dev/null || _install_status 1 "Unable to modify raspap.sudoers"
        fi
        echo "Enabling administration option for ${selected%%|*}"
        sudo sed -i "s/\('RASPI_VPN_PROVIDER_ENABLED', \)false/\1true/g" "$webroot_dir/includes/config.php" || _install_status 1 "Unable to modify config.php"

        echo "Adding VPN provider to $raspap_dir/provider.ini"
        if [ ! -f "$raspap_dir/provider.ini" ]; then
            sudo touch "$raspap_dir/provider.ini"
            echo "providerID = $answer" | sudo tee "$raspap_dir/provider.ini" > /dev/null || _install_status 1 "Unable to create $raspap_dir/provider.ini"
        elif ! grep -q "providerID = $answer" "$raspap_dir/provider.ini"; then
            echo "providerID = $answer" | sudo tee "$raspap_dir/provider.ini" > /dev/null || _install_status 1 "Unable to write to $raspap_dir/provider.ini"
        fi
    fi    
    _install_status 0
}

# Install Wireguard from the Debian unstable distro
function _install_wireguard() {
    _install_log "Configuring WireGuard support"
    if { [ "$OS" == "Debian" ] && [ "$RELEASE" == 12 ]; } ||
       { [ "$OS" == "Ubuntu" ] && [ "$RELEASE" == "22.04" ]; }; then
        wg_dep="resolvconf"
    fi
    echo "Installing wireguard from apt"
    sudo apt-get install -y wireguard $wg_dep || _install_status 1 "Unable to install wireguard"

    # create shim for resolvconf under debian 13
    if { ! command -v resolvconf >/dev/null || [ "$RELEASE" == 13 ]; } then
        echo "Applying resolvconf shim to prevent DNS conflicts"
        sudo ln -sf /usr/bin/true /usr/local/bin/resolvconf || _install_status 1 "Failed to apply resolvconf shim"
    fi

    _install_wireguard_killswitch
    _install_fake_hwclock

    echo "Enabling wg-quick@wg0"
    sudo systemctl enable wg-quick@wg0 || _install_status 1 "Failed to enable wg-quick service"
    echo "Enabling WireGuard management option"
    sudo sed -i "s/\('RASPI_WIREGUARD_ENABLED', \)false/\1true/g" "$webroot_dir/includes/config.php" || _install_status 1 "Unable to modify config.php"
    _install_status 0
}

# Install the WireGuard kill switch script
function _install_wireguard_killswitch() {
    echo "Copying installers/wg-killswitch.sh to $raspap_network"
    sudo install -o root -g root -m 750 "$webroot_dir/installers/wg-killswitch.sh" "${raspap_network}wg-killswitch.sh" || _install_status 1 "Unable to install wg-killswitch.sh"
    echo "Copying installers/wg-forward.sh to $raspap_network"
    sudo install -o root -g root -m 750 "$webroot_dir/installers/wg-forward.sh" "${raspap_network}wg-forward.sh" || _install_status 1 "Unable to install wg-forward.sh"

    # on install and on update
    _install_ntp_fallback
    _install_captive_portal
}

# Install the captive portal helper for the kill switch option "Allow captive
# portal login". The timer runs as root, so the script must be in a directory
# that only root can change. The probe runs as the system user raspap-probe,
# the only user that the kill switch lets send HTTP requests outside the tunnel.
# The installer does not start the timer: wg-killswitch.sh starts it when the
# tunnel starts with the option, and stops it with the tunnel.
function _install_captive_portal() {
    echo "Installing the captive portal helper"
    if ! id -u raspap-probe > /dev/null 2>&1; then
        sudo useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin raspap-probe ||
            _install_status 1 "Unable to create the user raspap-probe"
    fi
    # psl checks the DNS domain of the uplink against the Public Suffix List
    sudo apt-get install -y psl || _install_status 1 "Unable to install psl"
    sudo install -o root -g root -m 755 "$webroot_dir/installers/captive-portal.sh" /usr/local/sbin/raspap-captive-portal.sh ||
        _install_status 1 "Unable to install the captive portal helper"
    sudo install -o root -g root -m 644 "$webroot_dir/installers/raspap-captive-portal.service" /etc/systemd/system/raspap-captive-portal.service ||
        _install_status 1 "Unable to install raspap-captive-portal.service"
    sudo install -o root -g root -m 644 "$webroot_dir/installers/raspap-captive-portal.timer" /etc/systemd/system/raspap-captive-portal.timer ||
        _install_status 1 "Unable to install raspap-captive-portal.timer"
    sudo install -o root -g root -m 644 "$webroot_dir/installers/raspap-captive-portal-cleanup.service" /etc/systemd/system/raspap-captive-portal-cleanup.service ||
        _install_status 1 "Unable to install raspap-captive-portal-cleanup.service"
    sudo systemctl daemon-reload
    # removes portal mode at boot, for example after a power loss
    sudo systemctl enable raspap-captive-portal-cleanup.service || _install_status 1 "Unable to enable raspap-captive-portal-cleanup.service"
}

# Keep the clock across reboots, so that the WireGuard handshake does not fail
# because the clock is behind. fake-hwclock restores the last saved time at
# boot. Called on install only, not on update.
function _install_fake_hwclock() {
    # An RTC with a battery keeps the time. The RTC of a Raspberry Pi 5
    # (rpi-rtc) needs an optional battery, so it does not count.
    if [ -e /sys/class/rtc/rtc0/name ] && ! grep -q "rpi-rtc" /sys/class/rtc/rtc0/name; then
        echo "RTC found ($(cat /sys/class/rtc/rtc0/name)), fake-hwclock not installed"
        return 0
    fi
    echo "Installing fake-hwclock and saving the time every 5 minutes"
    sudo apt-get install -y fake-hwclock || _install_status 1 "Unable to install fake-hwclock"
    echo "*/5 * * * * root /usr/sbin/fake-hwclock save" | sudo tee /etc/cron.d/raspap-fake-hwclock >/dev/null || _install_status 1 "Unable to add fake-hwclock cron job"
}

# Add NTP servers by IP address. When the WireGuard tunnel is down and DNS goes
# through the tunnel, NTP server names do not resolve. The kill switch can let
# NTP pass outside the tunnel, so the clock can then be set from these servers.
# For systemd-timesyncd they are fallback servers; for ntpsec they are extra
# servers (see below).
function _install_ntp_fallback() {
    # time.cloudflare.com, see https://developers.cloudflare.com/time-services/ntp/usage/
    local servers="162.159.200.1 162.159.200.123 2606:4700:f1::1 2606:4700:f1::123"
    local server defaults

    # systemd-timesyncd (default): uses the fallback servers in turn
    if systemctl cat systemd-timesyncd.service > /dev/null 2>&1; then
        echo "Adding NTP fallback servers for systemd-timesyncd"
        # keep the default servers of the distribution first
        defaults=$(sed -n 's/^#\?FallbackNTP=//p' /etc/systemd/timesyncd.conf 2>/dev/null | head -n 1)
        sudo mkdir -p /etc/systemd/timesyncd.conf.d || _install_status 1 "Unable to create /etc/systemd/timesyncd.conf.d"
        printf '[Time]\nFallbackNTP=%s\n' "$(echo $defaults $servers)" |
            sudo tee /etc/systemd/timesyncd.conf.d/90-raspap.conf > /dev/null || _install_status 1 "Unable to add NTP fallback servers"
        sudo systemctl try-restart systemd-timesyncd.service
    fi

    # ntpsec (e.g. NTP Server plugin): ntpd reads each .conf file in the ntp.d
    # directory next to ntp.conf, after ntp.conf, without an includefile line
    # (see FILES in ntpd(8)). Thus the plugin does not change these servers.
    # ntpsec has no fallback-only option: ntpd uses these servers together with
    # the servers in ntp.conf and selects the best sources. When the server
    # names do not resolve, these servers are the only ones that work.
    if [ -d /etc/ntpsec ]; then
        echo "Adding NTP servers by IP address for ntpsec"
        sudo mkdir -p /etc/ntpsec/ntp.d || _install_status 1 "Unable to create /etc/ntpsec/ntp.d"
        {
            echo "# Added by RaspAP: NTP servers by IP address (time.cloudflare.com)."
            echo "# ntpd uses them together with the servers in ntp.conf. They keep"
            echo "# the clock correct when the server names do not resolve."
            for server in $servers; do
                echo "server $server iburst"
            done
        } | sudo tee /etc/ntpsec/ntp.d/90-raspap-fallback.conf > /dev/null || _install_status 1 "Unable to add NTP fallback servers"
        sudo systemctl try-restart ntpsec.service
    fi
}

# Update the WireGuard kill switch of an existing installation: install the
# script, update the kill switch rules in defaults.json and migrate the rules
# of older versions in the WireGuard configurations. A running tunnel keeps
# the old rule until it restarts.
function _update_wireguard() {
    if ! command -v wg-quick > /dev/null; then
        return 0
    fi
    _install_log "Updating WireGuard kill switch"
    _install_wireguard_killswitch

    local defaults="${raspap_network}defaults.json"
    if [ -f "$defaults" ]; then
        echo "Updating kill switch rules in $defaults"
        sudo php -r '
            $file = $argv[1];
            $legacy = "iptables -%s OUTPUT ! -o %%i -m mark ! --mark \$(wg show %%i fwmark) -m addrtype ! --dst-type LOCAL ! -d %%s -j REJECT";
            $old = file_get_contents($file);
            $json = $old;
            $json = str_replace(sprintf($legacy, "I"), "/etc/raspap/networking/wg-killswitch.sh up %i %s %o", $json);
            $json = str_replace(sprintf($legacy, "D"), "/etc/raspap/networking/wg-killswitch.sh down %i", $json);
            // the kill switch and the forwarding rules find the current AP when the tunnel starts
            $json = str_replace("/etc/raspap/networking/wg-killswitch.sh up %i %s %o", "/etc/raspap/networking/wg-killswitch.sh up %i %o", $json);
            $forward = "iptables -%1\$s FORWARD -i wlan0 -o %%i -j ACCEPT; iptables -%1\$s FORWARD -i %%i -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -%1\$s POSTROUTING -o %%i -j MASQUERADE";
            $json = str_replace(sprintf($forward, "A"), "/etc/raspap/networking/wg-forward.sh up %i %a", $json);
            $json = str_replace(sprintf($forward, "D"), "/etc/raspap/networking/wg-forward.sh down %i", $json);
            if ($json === $old) {
                exit(0);
            }
            // the file belongs to www-data in a sticky directory. With
            // fs.protected_regular=2, root can not open it with O_CREAT, so
            // open it without O_CREAT
            $fh = fopen($file, "r+");
            if ($fh === false || !ftruncate($fh, 0) || fwrite($fh, $json) !== strlen($json) || !fclose($fh)) {
                exit(1);
            }
        ' -- "$defaults" || _install_status 1 "Unable to update $defaults"
    fi

    echo "Migrating kill switch rules in WireGuard configurations"
    sudo find /etc/wireguard -maxdepth 1 -type f -name '*.conf' \
        -exec "${raspap_network}wg-killswitch.sh" migrate {} + || _install_status 1 "Unable to migrate WireGuard configurations"
    echo "Migrating forwarding rules in WireGuard configurations"
    sudo find /etc/wireguard -maxdepth 1 -type f -name '*.conf' \
        -exec "${raspap_network}wg-forward.sh" migrate {} + || _install_status 1 "Unable to migrate WireGuard configurations"
    _install_status 0
}

# Install openvpn and enable client configuration option
function _install_openvpn() {
    _install_log "Installing OpenVPN and enabling client configuration"
    echo "Adding packages via apt-get"
    sudo apt-get install -y openvpn || _install_status 1 "Unable to install openvpn"
    sudo sed -i "s/\('RASPI_OPENVPN_ENABLED', \)false/\1true/g" "$webroot_dir/includes/config.php" || _install_status 1 "Unable to modify config.php"
    echo "Enabling openvpn-client service on boot"
    sudo systemctl enable openvpn-client@client || _install_status 1 "Unable to enable openvpn-client daemon"
    _create_openvpn_scripts || _install_status 1 "Unable to create openvpn control scripts"
}

# Generate openvpn logging and auth control scripts
function _create_openvpn_scripts() {
    _install_log "Creating OpenVPN control scripts"
    sudo mkdir -p $raspap_dir/openvpn || _install_status 1 "Unable to create directory '$raspap_dir/openvpn'"

    # Copy service auth control and logging scripts
    sudo cp "$webroot_dir/installers/"configauth.sh "$raspap_dir/openvpn" || _install_status 1 "Unable to move auth control script"
    sudo cp "$webroot_dir/installers/"openvpnlog.sh "$raspap_dir/openvpn" || _install_status 1 "Unable to move logging script"
    # Restrict script execution to root user
    sudo chown -c root:root "$raspap_dir/openvpn/"*.sh || _install_status 1 "Unable change owner and/or group"
    sudo chmod 750 "$raspap_dir/openvpn/"*.sh || _install_status 1 "Unable to change file permissions"

    _install_status 0
}

# Update the OpenVPN control scripts of an existing installation. The script
# directory exists on all installations, so check for the script itself.
function _update_openvpn_scripts() {
    if [ ! -f "$raspap_dir/openvpn/configauth.sh" ]; then
        return 0
    fi
    _create_openvpn_scripts
}

# Makes a random RestAPI key when .env has no key. Without a key, the API
# refuses each request.
function _restapi_key() {
    local env_file="$raspap_dir/api/.env"
    if sudo grep -qE '^RASPAP_API_KEY=.+' "$env_file" 2>/dev/null; then
        return 0
    fi
    echo "Creating a RestAPI key"
    local key
    key=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
    { sudo grep -v '^RASPAP_API_KEY=' "$env_file" 2>/dev/null; echo "RASPAP_API_KEY=$key"; } |
        sudo tee "$env_file.new" > /dev/null || _install_status 1 "Unable to write the RestAPI key"
    sudo chown root:$raspap_user "$env_file.new"
    sudo chmod 640 "$env_file.new"
    sudo mv "$env_file.new" "$env_file" || _install_status 1 "Unable to write the RestAPI key"
}

# Only root and the web UI read the key in .env. systemd gives it to the
# service, also when the service runs as a user that can not read .env.
function _restapi_env_access() {
    local env_file="$raspap_dir/api/.env"
    if [ -f "$env_file" ] && [ ! -L "$env_file" ]; then
        sudo chgrp $raspap_user "$env_file" || _install_status 1 "Unable to change the group of $env_file"
        sudo chmod 640 "$env_file" || _install_status 1 "Unable to change the mode of $env_file"
    fi
    sudo mkdir -p /etc/systemd/system/restapi.service.d || _install_status 1 "Unable to create the restapi.service drop-in directory"
    printf '[Service]\nEnvironmentFile=-%s\n' "$env_file" |
        sudo tee /etc/systemd/system/restapi.service.d/raspap-env.conf > /dev/null || _install_status 1 "Unable to write the restapi.service drop-in"
    sudo systemctl daemon-reload
}

# The RestAPI modules are in a venv in $raspap_dir/api/venv, not in the system
# Python. The venv belongs to root: raspap-api can run it, but not change it.
# Returns 1 when the venv can not import the modules.
function _restapi_venv() {
    local venv="$raspap_dir/api/venv"
    # Debian has ensurepip, which venv needs, in the package python3-venv
    if ! dpkg-query -W -f='${Status}' python3-venv 2> /dev/null | grep -q "ok installed"; then
        sudo apt-get install -y python3-venv || { echo "Unable to install python3-venv" >&2; return 1; }
    fi
    if [ ! -x "$venv/bin/python" ]; then
        sudo python3 -m venv "$venv" || { echo "Unable to create $venv" >&2; return 1; }
    fi
    sudo "$venv/bin/pip" install -q -r "$raspap_dir/api/requirements.txt" || { echo "Unable to install the RestAPI modules" >&2; return 1; }
    sudo chown -R root:root "$venv"
    sudo "$venv/bin/python" -c 'import fastapi, uvicorn, dotenv, psutil' || { echo "The RestAPI venv is incomplete" >&2; return 1; }
}

# The service runs as the system user raspap-api, not as root or the user
# that installs RaspAP
function _restapi_user() {
    if ! id raspap-api > /dev/null 2>&1; then
        sudo useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin raspap-api ||
            _install_status 1 "Unable to create the user raspap-api"
    fi
}

# Installs the unit of the release: User=raspap-api, Python of the venv
function _restapi_unit() {
    sudo install -o root -g root -m 644 "$webroot_dir/installers/restapi.service" /lib/systemd/system/restapi.service ||
        _install_status 1 "Unable to install restapi.service"
    sudo systemctl daemon-reload
}

# Copies the RestAPI code of the update to $raspap_dir/api, and makes a key
# when there is none. Only when the RestAPI is installed. .env stays.
# The hardened fork also moves an older install to the venv and to the user
# raspap-api. The service stays enabled or disabled as it was.
function _update_restapi() {
    if [ ! -d "$raspap_dir/api" ]; then
        return 0
    fi
    _install_log "Updating RestAPI"
    if [ -d "$webroot_dir/api" ]; then
        sudo cp -r "$webroot_dir/api/." "$raspap_dir/api/" || _install_status 1 "Unable to copy the RestAPI files"
    fi
    _restapi_key
    _restapi_env_access
    if _restapi_venv; then
        _restapi_user
        _restapi_unit
    else
        # the old unit stays, so that a failed download does not stop a
        # RestAPI that works
        _install_status 2 "The RestAPI venv is not complete, the RestAPI service is not changed"
    fi
    sudo systemctl try-restart restapi.service
    _install_status 0
}

# Install and enable RestAPI configuration option
function _install_restapi() {
    _install_log "Installing and enabling RestAPI"
    sudo mv "$webroot_dir/api" "$raspap_dir/api"  || _install_status 1 "Unable to move api folder"
    # the web root, and so the code of the API, is owned by www-data
    sudo chown -R root:root "$raspap_dir/api" || _install_status 1 "Unable to change owner of api folder"

    if ! command -v python3 &> /dev/null; then
        sudo apt-get update
        sudo apt-get install -y python3 || _install_status 1 "Unable to install Python"
    fi
    # the modules go into a venv, not into the system Python
    _restapi_venv || _install_status 1 "Unable to install the RestAPI modules"
    _restapi_user
    echo "Installing restapi.service (user raspap-api, Python of the venv)"
    _restapi_unit
    _restapi_key
    _restapi_env_access
    sudo systemctl enable restapi.service || _install_status 1 "Failed to enable restapi.service"
    echo "Enabling RestAPI management option"
    sudo sed -i "s/\('RASPI_RESTAPI_ENABLED', \)false/\1true/g" "$webroot_dir/includes/config.php" || _install_status 1 "Unable to modify config.php"

    _install_status 0
}

# Saves the web root to /var/backups/raspap-webroot-<date>.tar.gz before an
# update removes it. Restore: tar -xzf <file> -C /
function _backup_webroot() {
    local backup_dir="/var/backups"
    local backup="$backup_dir/raspap-webroot-$(date +%F-%H%M%S).tar.gz"
    [ -d "$webroot_dir" ] || return 0
    _install_log "Saving the current web root to $backup"
    sudo mkdir -p "$backup_dir"
    # _check_for_old_configs moved config.php out of the web root already
    local extra=()
    if [ -f "${old_config_dir:-}/config.php" ]; then
        extra=(--transform="s|^config\.php\$|${webroot_dir#/}/includes/config.php|" -C "$old_config_dir" config.php)
    fi
    sudo tar -czf "$backup" -C / "${webroot_dir#/}" "${extra[@]}" || _install_status 1 "Unable to save the web root to $backup"
    sudo chmod 600 "$backup"
    local old
    for old in $(ls -1t "$backup_dir"/raspap-webroot-*.tar.gz 2>/dev/null | tail -n +4); do
        sudo rm -f "$old"
    done
}

# Installs the JavaScript files of the installed plugins again. An update
# removes app/js/plugins with the rest of the web root.
function _restore_plugin_javascript() {
    local dir js src
    for dir in "$webroot_dir"/plugins/*/; do
        [ -f "$dir/manifest.json" ] || continue
        while IFS= read -r js; do
            [ -n "$js" ] || continue
            src=$(realpath -e -- "$dir/$js" 2>/dev/null) || continue
            # only a file of the plugin itself
            case "$src" in
                "$(realpath -e -- "$dir")"/*) ;;
                *) continue ;;
            esac
            sudo install -D -o $raspap_user -g $raspap_user -m 644 "$src" "$webroot_dir/app/js/plugins/$(basename "$src")" ||
                _install_status 1 "Unable to install $(basename "$src")"
        done < <(php -r '$m = json_decode((string)file_get_contents($argv[1]), true); foreach ((array)($m["javascript"] ?? []) as $j) { if (is_string($j)) { echo $j, PHP_EOL; } }' -- "$dir/manifest.json")
    done
}

# Fetches latest files from github to webroot
function _download_latest_files() {
    _install_log "Cloning latest files from GitHub"
    # a private directory, not a fixed name in /tmp
    source_dir=$(mktemp -d) || _install_status 1 "Unable to create a temporary directory"
    git clone --branch $branch --depth 1 --recurse-submodules -c advice.detachedHead=false $git_source_url $source_dir || clone=false
    # the plugins submodule stays at the commit of the release (no --remote).
    # The plugin list of the hardened fork is config/plugins.json.

    if [ "$clone" = false ]; then
        _install_status 1 "Unable to download files from GitHub"
        echo "The installer cannot continue." >&2
        exit 1
    fi

    if [ -d "$webroot_dir" ] && [ "$update" == 0 ]; then
        sudo mv $webroot_dir "$webroot_dir.`date +%F-%R`" || _install_status 1 "Unable to move existing webroot directory"
    elif [ "$upgrade" == 1 ] || [ "$update" == 1 ]; then
        # A copy of the current web root, to restore it by hand when the update
        # fails. Keeps the 3 newest copies.
        _backup_webroot

        # The update installs root files from the new web root. Until the last
        # step, the web root belongs to root, so www-data can not change or
        # replace these files in the meantime.
        sudo chown root:root "$webroot_dir" && sudo chmod 755 "$webroot_dir" ||
            _install_status 1 "Unable to change the owner of $webroot_dir"

        # Keep the installed plugins in a private temporary directory: the
        # plugin directories and the symlinks of the bundled plugins
        plugins_keep=""
        if [ -d "$webroot_dir/plugins" ]; then
            plugins_keep=$(sudo mktemp -d /tmp/raspap-user-plugins.XXXXXX) || _install_status 1 "Unable to create a temporary directory"
            sudo cp -a "$webroot_dir/plugins/." "$plugins_keep/" || _install_status 1 "Unable to keep the installed plugins"
        fi

        sudo find "$webroot_dir" -mindepth 1 \
          ! -path "${webroot_dir}/ajax/system/sys_read_logfile.php" \
          ! -path "${webroot_dir}/plugins" \
          ! -path "${webroot_dir}/plugins/*" \
          -delete 2>/dev/null

        # Remove plugins to permit clean rsync
        sudo rm -rf "$webroot_dir/plugins"
    fi

    _install_log "Installing application to $webroot_dir"
    sudo rsync -av $exclude "$source_dir"/ "$webroot_dir"/ >/dev/null 2>&1 || _install_status 1 "Unable to install files to $webroot_dir"
    # rsync -a copies the mode 700 of the private clone directory
    sudo chmod 755 "$webroot_dir" || _install_status 1 "Unable to change the mode of $webroot_dir"

    # Restore user plugins after rsync. Symlinks too: a bundled plugin is a
    # symlink to plugins-available. Not the files of the plugins submodule.
    if [ "$upgrade" == 1 ] || [ "$update" == 1 ]; then
        if [ -n "${plugins_keep:-}" ] && [ -d "$plugins_keep" ]; then
            sudo find "$plugins_keep" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) ! -name .github \
                -exec cp -a {} "$webroot_dir/plugins/" \; || _install_status 1 "Unable to restore the installed plugins"
            sudo rm -rf "$plugins_keep"
        fi
        _restore_plugin_javascript
    fi

    if [ "$update" == 1 ]; then
        _install_log "Applying existing configuration to ${webroot_dir}/includes"
        sudo mv "$old_config_dir/config.php" $webroot_dir/includes  || _install_status 1 "Unable to move config.php to ${webroot_dir}/includes"
        # the device keeps its config.php, but the update check must use the
        # release endpoint of the new version
        local endpoint
        endpoint=$(grep -m1 "^define('RASPI_API_ENDPOINT'," "$webroot_dir/config/config.php" || true)
        if [ -n "$endpoint" ]; then
            sudo sed -i "s|^define('RASPI_API_ENDPOINT',.*|$endpoint|" "$webroot_dir/includes/config.php" || _install_status 1 "Unable to set the update endpoint in config.php"
        fi

        if [ -f "$old_config_dir/raspap.auth" ]; then
            _install_log "Applying existing authentication file to ${raspap_dir}"
            sudo mv "$old_config_dir/raspap.auth" $raspap_dir || _install_status 1 "Unable to restore authentification credentials file to ${raspap_dir}"
        fi
        sudo rmdir "$old_config_dir" 2>/dev/null || true
    else
        echo "Copying primary RaspAP config to ${webroot_dir}/includes/config.php"
        if [ ! -f "$webroot_dir/includes/config.php" ]; then
            sudo cp "$webroot_dir/config/config.php" "$webroot_dir/includes/config.php"
        fi
    fi
    echo "Removing source files at ${source_dir}"
    sudo rm -rf $source_dir

    _install_status 0
}

# Sets files ownership in web root directory
function _change_file_ownership() {
    if [ ! -d "$webroot_dir" ]; then
        _install_status 1 "Web root directory doesn't exist"
    fi

    _install_log "Changing file ownership in web root directory"
    sudo chown -R $raspap_user:$raspap_user "$webroot_dir" || _install_status 1 "Unable to change file ownership for '$webroot_dir'"
    # www-data writes as the owner. Other users and groups must not change the code.
    sudo chmod -R go-w "$webroot_dir" || _install_status 1 "Unable to change file permissions for '$webroot_dir'"
}

# Older versions saved the OpenVPN client configs and logins with mode 644, so
# each local user could read the keys and the VPN password, and owned by
# www-data, so the web server user could change a config that OpenVPN runs as
# root. Makes them owned by root and readable by root only. The web UI reads
# and changes them with raspap-vpn-file.sh. The same mode for the login files
# of the web UI (password hashes).
function _secure_openvpn_client_files() {
    local dir="/etc/openvpn/client" file
    if [ -d "$dir" ]; then
        sudo find "$dir" -maxdepth 1 -type f -name '*.conf' \( -perm /077 -o ! -user root -o ! -group root \) \
            -exec chown root:root {} + -exec chmod 600 {} + ||
            _install_status 1 "Unable to change the mode of the OpenVPN client files"
    fi
    for file in "$raspap_dir/raspap.auth" "$raspap_dir/limited.auth"; do
        if [ -f "$file" ] && [ ! -L "$file" ]; then
            sudo chmod 600 "$file" || _install_status 1 "Unable to change the mode of $file"
        fi
    done
}

# The web interface installs, reads and removes the WireGuard and OpenVPN
# client files with this helper (content on stdin, no file in /tmp). www-data
# can run it with sudo, so it must be in a directory that only root can change.
function _install_vpn_file_helper() {
    _install_log "Copying RaspAP VPN file helper to /usr/local/sbin"
    sudo install -o root -g root -m 755 "$webroot_dir/installers/vpn-file.sh" /usr/local/sbin/raspap-vpn-file.sh || _install_status 1 "Unable to install the VPN file helper"
}

# Check for existing configuration files
function _check_for_old_configs() {
    if [ "$update" == 1 ]; then
        # a private directory: other local users can not put files there that
        # the update then installs as config.php or raspap.auth
        old_config_dir=$(sudo mktemp -d /tmp/raspap-update.XXXXXX) || _install_status 1 "Unable to create a temporary directory"
        _install_log "Moving existing configuration to $old_config_dir"
        sudo mv $webroot_dir/includes/config.php "$old_config_dir/" || _install_status 1 "Unable to move config.php to $old_config_dir"
       if [ -f $raspap_dir/raspap.auth ]; then
            _install_log "Moving existing raspap.auth file to $old_config_dir"
            sudo mv $raspap_dir/raspap.auth "$old_config_dir/" || _install_status 1 "Unable to backup raspap.auth to $old_config_dir"
        fi
    else
        _install_log "Checking for existing configs"
        if [ -f /etc/network/interfaces ]; then
            sudo cp /etc/network/interfaces "$raspap_dir/backups/interfaces.`date +%F-%R`"
            sudo ln -sf "$raspap_dir/backups/interfaces.`date +%F-%R`" "$raspap_dir/backups/interfaces"
        fi

        if [ -f /etc/hostapd/hostapd.conf ]; then
            sudo cp /etc/hostapd/hostapd.conf "$raspap_dir/backups/hostapd.conf.`date +%F-%R`"
            sudo ln -sf "$raspap_dir/backups/hostapd.conf.`date +%F-%R`" "$raspap_dir/backups/hostapd.conf"
        fi

        if [ -f $raspap_default ]; then
            sudo cp $raspap_default "$raspap_dir/backups/090_raspap.conf.`date +%F-%R`"
            sudo ln -sf "$raspap_dir/backups/090_raspap.conf.`date +%F-%R`" "$raspap_dir/backups/090_raspap.conf"
        fi

        if [ -f $raspap_wlan0 ]; then
            sudo cp $raspap_wlan0 "$raspap_dir/backups/090_wlan0.conf.`date +%F-%R`"
            sudo ln -sf "$raspap_dir/backups/090_wlan0.conf.`date +%F-%R`" "$raspap_dir/backups/090_wlan0.conf"
        fi

        if [ -f /etc/dhcpcd.conf ]; then
            sudo cp /etc/dhcpcd.conf "$raspap_dir/backups/dhcpcd.conf.`date +%F-%R`"
            sudo ln -sf "$raspap_dir/backups/dhcpcd.conf.`date +%F-%R`" "$raspap_dir/backups/dhcpcd.conf"
        fi

        for file in /etc/systemd/network/raspap-*.net*; do
            if [ -f "${file}" ]; then
                filename=$(basename $file)
                sudo cp "$file" "${raspap_dir}/backups/${filename}.`date +%F-%R`"
                sudo ln -sf "${raspap_dir}/backups/${filename}.`date +%F-%R`" "${raspap_dir}/backups/${filename}"
            fi
        done
    fi
    _install_status 0
}

# Set up default configuration
function _default_configuration() {
    if [ "$upgrade" == 0 ]; then
        _install_log "Applying default configuration to installed services"

        echo "Checking for existence of /etc/dnsmasq.d"
        [ -d /etc/dnsmasq.d ] || sudo mkdir /etc/dnsmasq.d

        echo "Copying config/hostapd.conf to /etc/hostapd/hostapd.conf"
        # the WiFi password: root and the web interface (group www-data) only
        sudo install -o root -g www-data -m 640 $webroot_dir/config/hostapd.conf /etc/hostapd/hostapd.conf || _install_status 1 "Unable to move hostapd configuration file"

        echo "Copying config/090_raspap.conf to $raspap_default"
        sudo cp $webroot_dir/config/090_raspap.conf $raspap_default || _install_status 1 "Unable to move dnsmasq default configuration file"

        echo "Copying config/090_wlan0.conf to $raspap_wlan0"
        sudo cp $webroot_dir/config/090_wlan0.conf $raspap_wlan0 || _install_status 1 "Unable to move dnsmasq wlan0 configuration file"

        echo "Copying config/dhcpcd.conf to /etc/dhcpcd.conf"
        sudo cp $webroot_dir/config/dhcpcd.conf /etc/dhcpcd.conf || _install_status 1 "Unable to move dhcpcd configuration file"

        echo "Copying config/defaults.json to $raspap_network"
        sudo cp $webroot_dir/config/defaults.json $raspap_network || _install_status 1 "Unable to move defaults.json settings"

        echo "Changing file ownership of ${raspap_network}defaults.json"
        sudo chown $raspap_user:$raspap_user "$raspap_network"defaults.json || _install_status 1 "Unable to change file ownership for defaults.json"

        # Copy OS-specific bridge default config
        if [ ${OS,,} = "ubuntu" ] && [[ ${RELEASE} =~ ^(22.04|20.04|19.10|18.04) ]]; then
            echo "Copying bridged AP config to /etc/netplan"
            sudo cp $webroot_dir/config/raspap-bridge-br0.netplan /etc/netplan/raspap-bridge-br0.netplan || _install_status 1 "Unable to move br0 netplan file"
        else
            echo "Copying bridged AP config to /etc/systemd/network"
            sudo cp $webroot_dir/config/raspap-bridge-br0.netdev /etc/systemd/network/raspap-bridge-br0.netdev || _install_status 1 "Unable to move br0 netdev file"
            sudo cp $webroot_dir/config/raspap-br0-member-eth0.network /etc/systemd/network/raspap-br0-member-eth0.network || _install_status 1 "Unable to move br0 member file"
        fi

        if [ ${OS,,} = "raspbian" ] && [[ ${RELEASE} =~ ^(12) ]]; then
            echo "Moving dhcpcd systemd unit control file to /lib/systemd/system/"
            # a unit that runs as root must belong to root (mv keeps the owner www-data)
            sudo install -o root -g root -m 644 $webroot_dir/installers/dhcpcd.service /lib/systemd/system/dhcpcd.service || _install_status 1 "Unable to move dhcpcd.service file"
            sudo systemctl daemon-reload
            sudo systemctl enable dhcpcd.service || _install_status 1 "Failed to enable dhcpcd.service"
        fi

        # Set correct DAEMON_CONF path for hostapd (Ubuntu20 + Armbian22)
        if [ ${OS,,} = "ubuntu" ] && [[ ${RELEASE} =~ ^(22.04|20.04|19.10|18.04) ]]; then
            conf="/etc/default/hostapd"
            key="DAEMON_CONF"
            value="/etc/hostapd/hostapd.conf"
            echo "Setting default ${key} path to ${value}"
            sudo sed -i -E "/^#?$key/ { s/^#//; s%=.*%=\"$value\"%; }" "$conf" || _install_status 1 "Unable to set value in ${conf}"
        fi

        _install_log "Unmasking and enabling hostapd service"
        sudo systemctl unmask hostapd.service
        sudo systemctl enable hostapd.service

        _install_status 0
    else
        _install_log "Copying defaults.json to $raspap_network"
        sudo cp $webroot_dir/config/defaults.json $raspap_network || _install_status 1 "Unable to move defaults.json settings"
    fi
}

# Install and enable RaspAP daemon
function _enable_raspap_daemon() {
    _install_log "Enabling RaspAP daemon"
    echo "Disable with: sudo systemctl disable raspapd.service"
    sudo cp $webroot_dir/installers/raspapd.service /lib/systemd/system/ || _install_status 1 "Unable to move raspap.service file"
    sudo systemctl daemon-reload
    sudo systemctl enable raspapd.service || _install_status 1 "Failed to enable raspap.service"
}

# Install hostapd@.service
function _install_raspap_hostapd() {
    _install_log "Installing RaspAP hostapd@.service"
    sudo cp $webroot_dir/installers/hostapd@.service /etc/systemd/system/ || _install_status 1 "Unable to copy hostapd@.service file"
    sudo systemctl daemon-reload
    _install_status 0
}

# Configure IP forwarding, set IP tables rules, prompt to install RaspAP daemon
function _configure_networking() {
    _install_log "Configuring networking"
    echo "Enabling IP forwarding"
    echo "net.ipv4.ip_forward=1" | sudo tee $raspap_sysctl > /dev/null || _install_status 1 "Unable to set IP forwarding"
    sudo sysctl -p $raspap_sysctl || _install_status 1 "Unable to execute sysctl"
    sudo /etc/init.d/procps restart || _install_status 1 "Unable to execute procps"

    echo "Checking iptables rules"
    rules=(
    "-A POSTROUTING -j MASQUERADE"
    "-A POSTROUTING -s 192.168.50.0/24 ! -d 192.168.50.0/24 -j MASQUERADE"
    )
    for rule in "${rules[@]}"; do
        if sudo grep -- "$rule" $rulesv4 > /dev/null; then
            echo "Rule already exists: ${rule}"
        else
            rule=$(sed -e 's/^\(-A POSTROUTING\)/-t nat \1/' <<< $rule)
            echo "Adding rule: ${rule}"
            sudo iptables $rule || _install_status 1 "Unable to execute iptables"
            added=true
        fi
    done
    # Persist rules if added
    if [ "$added" = true ]; then
        echo "Persisting IP tables rules"
        # _patch_system_files installs the script later, so use the copy in the web root
        sudo bash "$webroot_dir/installers/raspap-iptables-save.sh" || _install_status 1 "Unable to execute iptables-save"
    fi

    # Prompt to install RaspAP daemon
    echo -n "Enable RaspAP control service (Recommended)? [Y/n]: "
    if [ "$assume_yes" == 0 ]; then
        read answer < /dev/tty
        if [ "$answer" != "${answer#[Nn]}" ]; then
            _install_status 0 "(Skipped)"
        else
            _enable_raspap_daemon
        fi
    else
        echo -e
        _enable_raspap_daemon
    fi

    # Enable RaspAP network activity monitor
    _enable_network_activity_monitor

    _install_status 0
 }

# Prints the interface of the network activity monitor. servicestart.sh
# starts the monitor for WifiInterface of hostapd.ini at boot, so use the same.
function _network_activity_interface() {
    local iface
    iface="$(sed -n 's/^[[:space:]]*WifiInterface[[:space:]]*=[[:space:]]*//p' "$raspap_dir/hostapd.ini" 2>/dev/null | tail -n 1 | tr -d '[:space:]')"
    [[ "$iface" =~ ^[A-Za-z0-9_.-]{1,15}$ ]] || iface="wlan0"
    echo "$iface"
}

# Install and enable RaspAP network activity monitor
function _enable_network_activity_monitor() {
    _install_log "Enabling RaspAP network activity monitor"
    echo "Compiling raspap-network-monitor.c to /usr/local/bin/"
    if ! command -v gcc >/dev/null 2>&1; then
        echo "gcc not found, installing..."
        sudo apt-get update
        sudo apt-get install -y build-essential || _install_status 1 "Failed to install build tools"
    fi
    sudo gcc -O2 -o /usr/local/bin/raspap-network-monitor $webroot_dir/installers/raspap-network-monitor.c || _install_status 1 "Failed to compile raspap-network-monitor.c"
    echo "Copying raspap-network-activity@.service to /lib/systemd/system/"
    sudo cp $webroot_dir/installers/raspap-network-activity@.service /lib/systemd/system/ || _install_status 1 "Unable to move raspap-network-activity.service file"
    sudo systemctl daemon-reload
    local iface unit other
    iface="$(_network_activity_interface)"
    unit="raspap-network-activity@${iface}.service"
    # all instances write /dev/shm/net_activity, so only one may run
    for other in $( { systemctl list-units --all --plain --no-legend 'raspap-network-activity@*.service' | awk '{print $1}'
                      ls /etc/systemd/system/multi-user.target.wants/ 2>/dev/null | grep '^raspap-network-activity@.*\.service$'; } | sort -u); do
        [ "$other" = "$unit" ] && continue
        echo "Disabling $other"
        sudo systemctl disable --now "$other" || _install_status 1 "Failed to disable $other"
    done
    echo "Enabling $unit"
    sudo systemctl enable "$unit" || _install_status 1 "Failed to enable $unit"
    # a restart, so that a monitor that runs uses the new program
    echo "Starting $unit"
    sudo systemctl restart "$unit" || _install_status 1 "Failed to start $unit"
    sleep 0.5
    echo "Symlinking /dev/shm/net_activity to $webroot_dir/app/net_activity"
    sudo ln -sf /dev/shm/net_activity $webroot_dir/app/net_activity || _install_status 1 "Failed to link net_activity to ${webroot_dir}/app"
    echo "Setting ownership for ${raspap_user} on ${webroot_dir}/app/net_activity"
    sudo chown -R $raspap_user:$raspap_user $webroot_dir/app/net_activity || _install_status 1 "Unable to set ownership of ${webroot_dir}/app/net_activity"
    echo "Network activity monitor enabled"
}

# Prompt to configure TCP BBR option
function _prompt_configure_tcp_bbr() {
    _install_log "Configure TCP BBR congestion control"
    echo "Network performance can be improved by changing TCP congestion control to BBR (Bottleneck Bandwidth and RTT)"
    echo -n "Enable TCP BBR congestion control algorithm (Recommended)? [Y/n]: "
    if [ "$assume_yes" == 0 ]; then
        read answer < /dev/tty
        if [ "$answer" != "${answer#[Nn]}" ]; then
            _install_status 0 "(Skipped)"
        else
            _configure_tcp_bbr
        fi
    elif [ "${bbr_option}" == 1 ]; then
        _configure_tcp_bbr
    else
        echo "(Skipped)"
    fi
}

function _configure_tcp_bbr() {
    echo "Checking kernel support for the TCP BBR algorithm..."
    _check_tcp_bbr_available
    if [ $? -eq 0 ]; then
        echo "TCP BBR option found. Enabling configuration"
        # Load the BBR module
        echo "Loading BBR kernel module"
        sudo modprobe tcp_bbr || _install_status 1 "Unable to execute modprobe tcp_bbr"
        # Add BBR configuration to sysctl.conf if not present
        echo "Adding BBR configuration to /etc/sysctl.conf if not present"
        if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
            echo "net.core.default_qdisc=fq" | sudo tee -a /etc/sysctl.conf || _install_status 1 "Unable to modify /etc/sysctl.conf"
        fi
        if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
            echo "net.ipv4.tcp_congestion_control=bbr" | sudo tee -a /etc/sysctl.conf || _install_status 1 "Unable to modify /etc/sysctl.conf"
        fi
        # Apply the sysctl changes
        echo "Applying changes"
        sudo sysctl -p || _install_status 1 "Unable to execute sysctl"

        # Verify if BBR is enabled
        cc=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
        if [ "$cc" == "bbr" ]; then
            echo "TCP BBR successfully enabled"
        else
            _install_status 1 "Failed to enable TCP BBR"
        fi
    else
        _install_status 2 "TCP BBR option is not available (Skipped)"
    fi
    _install_status 0
}

function _check_tcp_bbr_available() {
    if [[ "$(modinfo -F intree tcp_bbr)" =~ ^[Yy]$ ]]; then
        return 0
    else
        return 1
    fi
}

# Add sudoers file to /etc/sudoers.d/ and set file permissions
function _patch_system_files() {

    # Create sudoers
    _install_log "Adding raspap.sudoers to ${raspap_sudoers}"
    # The web update may run the installer only for this web root. Check the
    # file before it replaces the rules, because an invalid file breaks sudo.
    local sudoers_tmp
    sudoers_tmp=$(mktemp) || _install_status 1 "Unable to create a temporary file"
    sed "s#--path /var/www/html\$#--path ${webroot_dir}#" "$webroot_dir/installers/raspap.sudoers" > "$sudoers_tmp" || _install_status 1 "Unable to prepare raspap.sudoers"
    sudo visudo -cqf "$sudoers_tmp" || _install_status 1 "Invalid raspap.sudoers"
    sudo install -o root -g root -m 0440 "$sudoers_tmp" $raspap_sudoers || _install_status 1 "Unable to apply raspap.sudoers to $raspap_sudoers"
    rm -f "$sudoers_tmp"

    # The scripts that save iptables rules run as root, so the script that they
    # call must be in a directory that only root can change
    _install_log "Copying RaspAP iptables save script to /usr/local/sbin"
    sudo install -o root -g root -m 755 "$webroot_dir/installers/raspap-iptables-save.sh" /usr/local/sbin/raspap-iptables-save.sh || _install_status 1 "Unable to install iptables save script"

    if [ ! -d "$raspap_dir/system" ]; then
        sudo mkdir -p $raspap_dir/system || _install_status 1 "Unable to create directory '$raspap_dir/system'"
    fi

    _install_log "Copying RaspAP debug log control script"
    sudo cp "$webroot_dir/installers/"debuglog.sh "$raspap_dir/system" || _install_status 1 "Unable to move debug logging script"

    # The update runs this file. bash reads a script while it runs, so cp over
    # the file makes bash run lines of the new file. A new file and mv keep the
    # running file unchanged.
    _install_log "Copying RaspAP install loader"
    sudo install -o root -g root -m 750 "$webroot_dir/installers/raspbian.sh" "$raspap_dir/system/.raspbian.sh.new" &&
        sudo mv -f "$raspap_dir/system/.raspbian.sh.new" "$raspap_dir/system/raspbian.sh" || _install_status 1 "Unable to move application update script"

    # www-data can run this script with sudo, so it must be in a directory that
    # only root can change
    _install_log "Copying RaspAP set time script to /usr/local/sbin"
    sudo install -o root -g root -m 755 "$webroot_dir/installers/settime.sh" /usr/local/sbin/raspap-settime.sh || _install_status 1 "Unable to install set time script"

    _install_vpn_file_helper
    _install_uplink_watchdog
    _install_vnstat_helper
    _install_config_file_helper

    # Set ownership and permissions
    sudo chown -c root:root "$raspap_dir/system/"*.sh || _install_status 1 "Unable change owner and/or group"
    sudo chmod 750 "$raspap_dir/system/"*.sh || _install_status 1 "Unable to change file permissions"

    # Add symlink to prevent wpa_cli cmds from breaking with multiple wlan interfaces
    _install_log "Symlinked wpa_supplicant hooks for multiple wlan interfaces"
    if [ ! -f /usr/share/dhcpcd/hooks/10-wpa_supplicant ]; then
        sudo ln -s /usr/share/dhcpcd/hooks/10-wpa_supplicant /etc/dhcp/dhclient-enter-hooks.d/
    fi

    # www-data runs the NetworkManager WiFi client helper with sudo, so it must
    # be in a directory that only root can change
    _install_log "Copying RaspAP NetworkManager WiFi client helper to /usr/local/sbin"
    sudo install -o root -g root -m 755 "$webroot_dir/installers/nm-wifi.sh" /usr/local/sbin/raspap-nm-wifi.sh || _install_status 1 "Unable to install NetworkManager WiFi client helper"

    # www-data runs wpa_cli, wpa_supplicant and iw through this helper, and
    # installs wpa_supplicant.conf with it. It must be in a directory that only
    # root can change.
    _install_log "Copying RaspAP WiFi helper to /usr/local/sbin"
    sudo install -o root -g root -m 755 "$webroot_dir/installers/wifi.sh" /usr/local/sbin/raspap-wifi.sh || _install_status 1 "Unable to install WiFi helper"

    # www-data changes the udev rules of network devices through this helper.
    # The rules files belong to root.
    _install_log "Copying RaspAP udev rules helper to /usr/local/sbin"
    sudo install -o root -g root -m 755 "$webroot_dir/installers/udev-rules.sh" /usr/local/sbin/raspap-udev-rules.sh || _install_status 1 "Unable to install udev rules helper"
    for rules in /etc/udev/rules.d/70-mobile-data-sticks.rules /etc/udev/rules.d/80-raspap-net-devices.rules; do
        if [ -f "$rules" ]; then
            sudo chown root:root "$rules" && sudo chmod 644 "$rules" || _install_status 1 "Unable to set permissions of $rules"
        fi
    done

    # www-data runs ip, iw and nmap, changes wvdial.conf, and reads and clears
    # the service logs through these helpers. They must be in a directory that
    # only root can change.
    _install_log "Copying RaspAP network tools and log helpers to /usr/local/sbin"
    sudo install -o root -g root -m 755 "$webroot_dir/installers/net.sh" /usr/local/sbin/raspap-net.sh || _install_status 1 "Unable to install network tools helper"
    sudo install -o root -g root -m 755 "$webroot_dir/installers/logs.sh" /usr/local/sbin/raspap-logs.sh || _install_status 1 "Unable to install log helper"

    # The root helpers of the Firewall and NTP Server plugins, and the files of the Tailscale
    # plugin that run as root. plugin_helper.sh refuses these paths, so the
    # installer installs them.
    sudo install -o root -g root -m 755 "$webroot_dir/installers/firewall.sh" /usr/local/sbin/raspap-firewall.sh || _install_status 1 "Unable to install firewall helper"
    # the root helper of the NTP Server plugin
    sudo install -o root -g root -m 755 "$webroot_dir/installers/ntp.sh" /usr/local/sbin/raspap-ntp.sh || _install_status 1 "Unable to install NTP helper"
    # the blocklist update script reads its URLs from a root-owned file, and
    # keeps only blocking lines. The installed lists get the same filter.
    if [ -d "$raspap_dir/adblock" ]; then
        _install_blocklist_script
        sudo "$raspap_dir/adblock/update_blocklist.sh" clean || _install_status 1 "Unable to filter the blocklists"
    fi
    # writes the RestAPI key to .env: www-data no longer moves a file there
    sudo install -o root -g root -m 755 "$webroot_dir/installers/api-key.sh" /usr/local/sbin/raspap-api-key.sh || _install_status 1 "Unable to install the RestAPI key helper"

    # The units that RaspAP installs run as root, so they belong to root. Older
    # versions moved some of them from the web root (owner www-data). The
    # hostapd configurations hold the WiFi password: root and www-data only.
    local unit
    for unit in /lib/systemd/system/{dhcpcd,raspapd,restapi,raspap-network-activity@}.service \
        /etc/systemd/system/{hostapd@,raspap-captive-portal,raspap-captive-portal-cleanup,raspap-uplink-watchdog}.service \
        /etc/systemd/system/{raspap-captive-portal,raspap-uplink-watchdog}.timer; do
        if [ -f "$unit" ] && [ ! -L "$unit" ]; then
            sudo chown root:root "$unit" && sudo chmod go-w "$unit" || _install_status 1 "Unable to change the owner of $unit"
        fi
    done
    local conf
    for conf in /etc/hostapd/hostapd.conf /etc/hostapd/hostapd-*.conf; do
        if [ -f "$conf" ] && [ ! -L "$conf" ]; then
            sudo chown root:www-data "$conf" && sudo chmod 640 "$conf" || _install_status 1 "Unable to change the mode of $conf"
        fi
    done
    local ts_config="$webroot_dir/plugins-available/Tailscale/config"
    if [ -f "$ts_config/ts-optimize.sh" ] && [ -f "$ts_config/tailscale-ethtool@.service" ]; then
        sudo install -o root -g root -m 755 "$ts_config/ts-optimize.sh" /usr/local/sbin/raspap-ts-optimize.sh || _install_status 1 "Unable to install ts-optimize.sh"
        sudo install -o root -g root -m 644 "$ts_config/tailscale-ethtool@.service" /etc/systemd/system/tailscale-ethtool@.service || _install_status 1 "Unable to install tailscale-ethtool@.service"
        sudo systemctl daemon-reload
    fi

    _install_status 0
}


# Install the uplink watchdog. The timer runs as root and www-data can run
# the script with sudo, so the script must be in a directory that only root
# can change. The timer is off by default, and an update keeps its state.
function _install_uplink_watchdog() {
    _install_log "Copying RaspAP uplink watchdog to /usr/local/sbin"
    sudo install -o root -g root -m 755 "$webroot_dir/installers/uplink-watchdog.sh" /usr/local/sbin/raspap-uplink-watchdog.sh || _install_status 1 "Unable to install uplink watchdog script"
    sudo install -o root -g root -m 644 "$webroot_dir/installers/raspap-uplink-watchdog.service" /etc/systemd/system/raspap-uplink-watchdog.service || _install_status 1 "Unable to install raspap-uplink-watchdog.service"
    sudo install -o root -g root -m 644 "$webroot_dir/installers/raspap-uplink-watchdog.timer" /etc/systemd/system/raspap-uplink-watchdog.timer || _install_status 1 "Unable to install raspap-uplink-watchdog.timer"
    sudo systemctl daemon-reload
}

# The web interface installs the configuration files of hostapd, dhcpcd and
# dnsmasq with this helper (content on stdin, no file in /tmp). www-data can
# run it with sudo, so it must be in a directory that only root can change.
function _install_config_file_helper() {
    _install_log "Copying RaspAP config file helper to /usr/local/sbin"
    sudo install -o root -g root -m 755 "$webroot_dir/installers/config-file.sh" /usr/local/sbin/raspap-config-file.sh || _install_status 1 "Unable to install the config file helper"
}

# vnstat adds only the interfaces that exist when it is installed. This helper
# adds the interfaces that RaspAP configures, also on an update. www-data can
# run it with sudo, so it must be in a directory that only root can change.
function _install_vnstat_helper() {
    _install_log "Copying RaspAP vnstat helper to /usr/local/sbin"
    sudo install -o root -g root -m 755 "$webroot_dir/installers/vnstat.sh" /usr/local/sbin/raspap-vnstat.sh || _install_status 1 "Unable to install vnstat helper"
    if command -v vnstat > /dev/null; then
        sudo /usr/local/sbin/raspap-vnstat.sh sync || echo "Unable to add the interfaces to vnstat"
    fi
}

# Optimize configuration of php-cgi.
function _optimize_php() {
    if [ "$upgrade" == 0 ]; then
        _install_log "Optimize PHP configuration"
        if [ ! -f "$phpiniconf" ]; then
            _install_status 2 "PHP configuration could not be found."
            return
        fi

        # Backup php.ini and create symlink for restoring.
        datetimephpconf=$(date +%F-%R)
        sudo cp "$phpiniconf" "$raspap_dir/backups/php.ini.$datetimephpconf"
        sudo ln -sf "$raspap_dir/backups/php.ini.$datetimephpconf" "$raspap_dir/backups/php.ini"

        echo -n "Enable HttpOnly for session cookies (Recommended)? [Y/n]: "
        if [ "$assume_yes" == 0 ]; then
            read answer < /dev/tty
            if [ "$answer" != "${answer#[Nn]}" ]; then
                echo -e
            else
                 php_session_cookie=1;
            fi
        fi

        if [ "$assume_yes" == 1 ] || [ "$php_session_cookie" == 1 ]; then
            echo "Php-cgi enabling session.cookie_httponly."
            sudo sed -i -E 's/^session\.cookie_httponly\s*=\s*(0|([O|o]ff)|([F|f]alse)|([N|n]o))\s*$/session.cookie_httponly = 1/' "$phpiniconf"
        fi

        if [ "$php_package" = "php7.1-cgi" ]; then
            echo -n "Enable PHP OPCache (Recommended)? [Y/n]: "
            if [ "$assume_yes" == 0 ]; then
                read answer < /dev/tty
                if [ "$answer" != "${answer#[Nn]}" ]; then
                    echo -e
                else
                    php_opcache=1;
                fi
            fi

            if [ "$assume_yes" == 1 ] || [ "$phpopcache" == 1 ]; then
                echo -e "Php-cgi enabling opcache.enable."
                sudo sed -i -E 's/^;?opcache\.enable\s*=\s*(0|([O|o]ff)|([F|f]alse)|([N|n]o))\s*$/opcache.enable = 1/' "$phpiniconf"
                # Make sure opcache extension is turned on.
                if [ -f "/usr/sbin/phpenmod" ]; then
                    sudo phpenmod opcache
                else
                    _install_status 2 "phpenmod not found."
                fi
            fi
        fi
    fi
}

# search for optional installation files names install_feature_*.sh
function _install_extra_features() {
    _install_log "Installing additional features"
    for feature in $(ls $webroot_dir/installers/install_feature_*.sh) ; do
       source $feature
       f=$(basename $feature)
       func="_${f%.*}"
       if declare -f -F $func > /dev/null; then
            $func || _install_status 1 "Unable to install feature ($func)"
        else
            _install_status 1 "Install file $f is missing install function $func"
       fi
   done
}

function _install_complete() {
    _install_log "Installation completed"
    echo "Thank you for supporting this project!"
    echo -e "${ANSI_RASPBERRY}"
    echo "> https://github.com/sponsors/RaspAP/"
    echo -e "${ANSI_RESET}"
    if [ "$assume_yes" == 0 ]; then
        # Prompt to reboot if wired ethernet (eth0) is connected.
        # With default_configuration this will create an active AP on restart.
        if ip a | grep -q ': eth0:.*state UP'; then
            echo -n "The system needs to be rebooted as a final step. Reboot now? [Y/n]: "
            read answer < /dev/tty
            if [ "$answer" != "${answer#[Nn]}" ]; then
                echo "Installation reboot aborted."
                exit 0
            fi
            sudo shutdown -r now || _install_status 1 "Unable to execute shutdown"
        fi
    fi
}

