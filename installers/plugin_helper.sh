#!/bin/bash
#
# PluginInstaller helper for RaspAP 
# @author billz
# license: GNU General Public License v3.0

# Exit on error
set -o errexit
set -o pipefail

readonly raspap_user="www-data"
readonly webroot_dir="/var/www/html"

# The hardened fork: a plugin must not replace or change the files of RaspAP
# and of the system. These paths are refused for "config" and "permissions".
readonly protected_paths=(
    /bin /boot /dev /etc/sudoers /etc/sudoers.d /etc/passwd /etc/shadow
    /etc/group /etc/gshadow /etc/systemd /etc/udev /etc/iptables /etc/nftables.conf
    /etc/wireguard /etc/openvpn /etc/hostapd /etc/dnsmasq.conf /etc/dnsmasq.d
    /etc/dhcpcd.conf /etc/wpa_supplicant /etc/NetworkManager /etc/network
    /etc/lighttpd /etc/php /etc/apt /etc/cron.d /etc/crontab /etc/ssh
    /etc/raspap /lib /lib64 /proc /root /run /sbin /sys /usr /var/lib
    "$webroot_dir"
)
# Exceptions in the protected paths: plugin data in the web root
readonly allowed_paths=(
    "$webroot_dir/plugins" "$webroot_dir/app/js/plugins" "$webroot_dir/config"
)

# Prints the absolute path of $1 without symlinks (also when it does not exist)
real_path() {
    realpath -m -- "$1"
}

# Returns 0 when $1 is equal to or below one of the following paths
below() {
    local path="$1" p
    shift
    for p in "$@"; do
        if [ "$path" = "$p" ] || [[ "$path" == "$p"/* ]]; then
            return 0
        fi
    done
    return 1
}

# Refuses a destination that belongs to RaspAP or to the system
check_destination() {
    local dest
    dest="$(real_path "$1")"
    if below "$dest" "${allowed_paths[@]}"; then
        return 0
    fi
    if [ "$dest" = / ] || below "$dest" "${protected_paths[@]}"; then
        echo "Error: a plugin can not change $dest." >&2
        exit 1
    fi
}

# Checks the rules of a plugin sudoers file. Each rule is for www-data, and the
# command must be a program that www-data can not change.
check_sudoers() {
    local file="$1" line cmds cmd path
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
        if [[ ! "$line" =~ ^www-data\ ALL=\(ALL\)\ NOPASSWD:(.+)$ ]]; then
            echo "Error: only rules for www-data are allowed: $line" >&2
            return 1
        fi
        cmds="${BASH_REMATCH[1]}"
        IFS=',' read -r -a cmd <<< "$cmds"
        for path in "${cmd[@]}"; do
            path="${path#"${path%%[![:space:]]*}"}"
            path="${path%% *}"
            if [[ "$path" != /* ]] || [ "$path" = ALL ]; then
                echo "Error: the command must be an absolute path: $path" >&2
                return 1
            fi
            # www-data can write in these directories
            if below "$(real_path "$path")" /tmp /var/tmp /dev/shm /run/user /home "$webroot_dir" /etc/raspap; then
                echo "Error: www-data can change the command $path." >&2
                return 1
            fi
            # the program can be installed later (dependencies), but when it
            # exists, it must belong to root and not be writable by others
            if [ -e "$path" ]; then
                if [ "$(stat -L -c %u "$path")" != 0 ] || [ -n "$(find -L "$path" -maxdepth 0 -perm /022)" ]; then
                    echo "Error: www-data or other users can change the command $path." >&2
                    return 1
                fi
            fi
        done
    done < "$file"
}

[ $# -lt 1 ] && { echo "Usage: $0 <action> [parameters...]"; exit 1; }

action="$1"  # action to perform
shift 1      

case "$action" in

  "sudoers")
    [ $# -ne 1 ] && { echo "Usage: $0 sudoers <file>"; exit 1; }
    file="$1"
    plugin_name=$(basename "$file")
    # PluginInstaller writes /tmp/090_<plugin name>. 090_raspap is the file of RaspAP.
    if [ "$(dirname "$file")" != /tmp ] || [ -L "$file" ] || [ ! -f "$file" ] ||
        [[ ! "$plugin_name" =~ ^090_[A-Za-z0-9_-]{1,64}$ ]] || [ "${plugin_name,,}" = 090_raspap ]; then
        echo "Error: invalid sudoers file $file."
        exit 1
    fi
    dest="/etc/sudoers.d/${plugin_name}"

    # check a private copy, so that the file can not change after the checks
    tmp=$(mktemp /etc/sudoers.d/.plugin.XXXXXX) || { echo "Error: Failed to create a temporary file."; exit 1; }
    trap 'rm -f "$tmp"' EXIT
    cat -- "$file" > "$tmp"
    rm -f -- "$file"
    chown root:root "$tmp"
    chmod 0440 "$tmp"
    check_sudoers "$tmp" || { echo "Error: the sudoers rules of the plugin are refused."; exit 1; }
    visudo -cqf "$tmp" || { echo "Error: invalid sudoers file."; exit 1; }
    mv -f "$tmp" "$dest" || { echo "Error: Failed to move $file to $dest."; exit 1; }

    echo "OK"
    ;;

  "packages")
    [ $# -lt 1 ] && { echo "Usage: $0 packages <apt_packages...>"; exit 1; }

    for package in "$@"; do
      apt-get install -y "$package" || { echo "Error: Failed to install $package."; exit 1; }
    done
    echo "OK"
    ;;

  "deb")
    [ $# -lt 1 ] && { echo "Usage: $0 deb <deb_file>"; exit 1; }
    deb_file="$1"

    if [ ! -f "$deb_file" ]; then
        echo "Error: File not found: $deb_file"
        exit 1
    fi

    echo "Installing .deb package: $deb_file"
    dpkg -i "$deb_file"

    echo "OK"
    ;;

  "user")
    [ $# -lt 2 ] && { echo "Usage: $0 user <username> <password>."; exit 1; }

    username=$1
    password=$2

    if id "$username" &>/dev/null; then # user already exists
        echo "OK"
        exit 0
    fi
    # create the user without shell access
    useradd -r -s /bin/false "$username"

    # set password non-interactively
    echo "$username:$password" | chpasswd

    echo "OK"
    ;;

  "config")
    [ $# -lt 2 ] && { echo "Usage: $0 config <source> <destination>"; exit 1; }

    source=$1
    destination=$2

    if [ ! -f "$source" ]; then
        echo "Source file $source does not exist."
        exit 1
    fi
    # a destination that ends with / is a directory
    if [[ "$destination" == */ ]] || [ -d "$destination" ]; then
        destination="${destination%/}/$(basename "$source")"
    fi
    check_destination "$destination"
    if [ -L "$destination" ] || [ -d "$destination" ]; then
        echo "Error: $destination is a link or a directory."
        exit 1
    fi

    mkdir -p "$(dirname "$destination")"
    # files outside the web root belong to root: the plugins change them with
    # sudo. Only the plugin data in the web root belongs to www-data.
    if below "$(real_path "$destination")" "${allowed_paths[@]}"; then
        install -o "$raspap_user" -g "$raspap_user" -m 644 "$source" "$destination"
    else
        install -o root -g root -m 644 "$source" "$destination"
    fi

    echo "OK"
    ;;

  "permissions")
    [ $# -lt 4 ] && { echo "Usage: $0 permissions <filepath> <user> <group> <mode>"; exit 1; }

    filepath="$1"
    user="$2"
    group="$3"
    mode="$4"

    if [ ! -e "$filepath" ]; then
        echo "File not found: $filepath" >&2
        exit 1
    fi
    check_destination "$filepath"
    if [ -L "$filepath" ]; then
        echo "Error: $filepath is a link." >&2
        exit 1
    fi
    if ! [[ "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$group" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$mode" =~ ^0?[0-7]{3}$ ]]; then
        echo "Error: invalid owner, group or mode." >&2
        exit 1
    fi

    chown "$user:$group" "$filepath" || exit 1
    chmod "$mode" "$filepath" || exit 1

    echo "OK"
    ;;

  "javascript")
    [ $# -lt 2 ] && { echo "Usage: $0 javascript <source> <destination>"; exit 1; }

    source=$1
    destination=$2

    if [ ! -f "$source" ]; then
        echo "Source file $source does not exist."
        exit 1
    fi

    if [ "$(real_path "$destination")" != "$webroot_dir/app/js/plugins" ]; then
        echo "Error: invalid JavaScript destination $destination."
        exit 1
    fi
    if [ ! -d "$destination" ]; then
        mkdir -p "$destination"
    fi

    install -o "$raspap_user" -g "$raspap_user" -m 644 "$source" "$destination/$(basename "$source")"

    echo "OK"
    ;;


  "plugin")
    [ $# -lt 2 ] && { echo "Usage: $0 plugin <source> <destination>"; exit 1; }

    source=$1
    destination=$2

    if [ ! -d "$source" ]; then
        echo "Source directory $source does not exist."
        exit 1
    fi

    plugin_dir=$(dirname "$destination")
    if [ "$(real_path "$plugin_dir")" != "$webroot_dir/plugins" ] ||
        [[ ! "$(basename "$destination")" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || [ -e "$destination" ]; then
        echo "Error: invalid plugin destination $destination."
        exit 1
    fi
    if [ ! -d "$plugin_dir" ]; then
        mkdir -p "$plugin_dir"
    fi

    cp -R "$source" "$destination"
    chown -R $raspap_user:$raspap_user "$destination"

    echo "OK"
    ;;

  "keys")
    [ $# -ne 4 ] && { echo "Usage: $0 keys <key_url> <keyring> <repo> <sources>"; exit 1; }

    key_url="$1"
    keyring="$2"
    repo="$3"
    list_file="$4"

    # add repository GPG key if it doesn't already exist (a 0-byte file counts as missing,
    # since that's what a failed download leaves behind)
    if [ ! -s "$keyring" ]; then
        echo "Downloading GPG key from $key_url..."
        curl -fsSL "$key_url" | sudo tee "$keyring" > /dev/null || { echo "Error: Failed to download GPG key."; sudo rm -f "$keyring"; exit 1; }
    else
        echo "Repository GPG key already exists at $keyring"
    fi

    # add repository list if not present
    if [ ! -s "$list_file" ]; then
        echo "Adding repository $repo to sources list"
        curl -fsSL "$repo" | sudo tee "$list_file" > /dev/null || { echo "Error: Failed to add repository to sources list."; sudo rm -f "$list_file"; exit 1; }
        update_required=1
    else
        echo "Repository already exists in sources list"
    fi

    # update apt package list if required
    if [ "$update_required" == "1" ]; then
        sudo apt-get update || { echo "Error: Failed to update apt"; exit 1; }
    fi

    echo "OK"
    ;;

  *)
    echo "Invalid action: $action"
    echo "Usage: $0 <action> [parameters...]"
    echo "Actions:"
    echo "  sudoers <file>                              Install a sudoers file"
    echo "  packages <packages>                         Install aptitude package(s)"
    echo "  user <name> <password>                      Add user non-interactively"
    echo "  config <source <destination>                Applies a config file"
    echo "  javascript <source> <destination>           Applies a JavaScript file"
    echo "  plugin <source> <destination>               Copies a plugin directory"
    echo "  keys <key_url> <keyring> <repo> <sources>   Installs a GPG key for a third-party repo"
    exit 1
    ;;
esac
