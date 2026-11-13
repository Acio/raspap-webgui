#!/bin/bash
#
# Shared functions of the test suites of the hardened fork. The suites run in
# the test container (tests/fork/Dockerfile). The repository is at /s, read only.

set -u
ok=0
fail=0
readonly S=/s
readonly W=/var/www/html

# c <name> <test>: runs the test with eval and counts the result
c() {
    if eval "$2"; then
        ok=$((ok + 1)); echo "ok   $1"
    else
        fail=$((fail + 1)); echo "FAIL $1"
    fi
}

# Prints the result. The exit code is 1 when a test failed.
finish() {
    echo "RESULT: $ok ok, $fail fail"
    [ "$fail" = 0 ]
}

# A copy of the repository as the web root, as the installer makes it
setup_webroot() {
    mkdir -p "$W"
    (cd "$S" && tar --exclude=.git --exclude=node_modules -cf - .) | tar -xf - -C "$W"
    cp "$W/config/config.php" "$W/includes/config.php"
    chown -R www-data:www-data "$W"
    chmod -R go-w "$W"
}

# Sets an admin password that is not the default. With the default password,
# RaspAP 3.5.10 sends a logged-in admin to the password change page.
set_admin_password() {
    mkdir -p /etc/raspap
    php -r 'echo "admin\n", password_hash("fork-test-password", PASSWORD_BCRYPT), "\n";' > /etc/raspap/raspap.auth
    chown www-data /etc/raspap/raspap.auth
    chmod 600 /etc/raspap/raspap.auth
}

# Installs the sudoers file of RaspAP
setup_sudoers() {
    cp "$S/installers/raspap.sudoers" /etc/sudoers.d/090_raspap
    chmod 440 /etc/sudoers.d/090_raspap
}

# Creates an empty program for each path that does not exist, so that
# "sudo -l" can check a rule for a program that the container does not have
stub_programs() {
    local p
    for p in "$@"; do
        [ -e "$p" ] && continue
        mkdir -p "$(dirname "$p")"
        printf '#!/bin/sh\nexit 0\n' > "$p"
        chmod 755 "$p"
    done
}

# Prints the sudoers rules of a plugin manifest
manifest_sudoers() {
    php -r 'echo implode(PHP_EOL, json_decode(file_get_contents($argv[1]), true)["sudoers"] ?? []).PHP_EOL;' -- "$1"
}
