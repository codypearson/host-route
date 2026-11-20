#!/usr/bin/env bash
# Install host-route where root can run it. sing-box and the other commands
# this program runs must already be installed. This script does not call a
# package manager.
#
#   sudo ./install.sh
#   sudo ./install.sh uninstall
#   sudo ./install.sh uninstall --purge
#
# Re-running install replaces the program and the systemd unit. The host
# list and connection name in /etc/host-route/ are created once and then
# left alone. uninstall leaves that directory in place. uninstall --purge
# removes it. sing-box is not removed.
#
# sudo on some systems sets secure_path to /usr/sbin:/usr/bin:/sbin:/bin and
# will not search /usr/local/bin. When that is the effective secure_path,
# this script also links /usr/bin/host-route to the copy under /usr/local/bin.

set -euo pipefail

PREFIX="/usr/local"
NAME="host-route"
BIN_PATH="${PREFIX}/bin/${NAME}"
SHARE_DIR="${PREFIX}/share/${NAME}"
ETC_DIR="/etc/${NAME}"
SUDO_LINK="/usr/bin/${NAME}"
UNIT_PATH="/etc/systemd/system/${NAME}.service"
DISPATCHER_PATH="/etc/NetworkManager/dispatcher.d/90-${NAME}"

# Commands the program runs. The hint is the upstream project, not a
# distribution package name.
REQUIRED_COMMANDS=(
    sing-box
    python3
    ip
    systemctl
    systemd-notify
    nmcli
    dig
    curl
)

PROJECT_DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)

die() {
    echo "install.sh: $*" >&2
    exit 1
}

# What to install for a missing command. Keep this free of a particular
# distribution's package manager and package names.
command_hint() {
    case "$1" in
        sing-box)
            printf '%s\n' "sing-box — https://sing-box.sagernet.org/installation/package-manager/"
            ;;
        python3)
            printf '%s\n' "Python 3"
            ;;
        ip)
            printf '%s\n' "iproute2"
            ;;
        systemctl|systemd-notify)
            printf '%s\n' "systemd"
            ;;
        nmcli)
            printf '%s\n' "NetworkManager"
            ;;
        dig)
            printf '%s\n' "BIND (the dig command)"
            ;;
        curl)
            printf '%s\n' "curl"
            ;;
        *)
            printf '%s\n' "$1"
            ;;
    esac
}

# Stop when a required command is absent. The operator installs it.
require_commands() {
    local cmd
    local -a missing=()
    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done
    [[ ${#missing[@]} -eq 0 ]] && return 0
    echo "install.sh: missing commands: ${missing[*]}" >&2
    echo "Install the packages that provide them with your distribution's package manager, then run install.sh again." >&2
    for cmd in "${missing[@]}"; do
        echo "  ${cmd}: $(command_hint "$cmd")" >&2
    done
    exit 1
}

# The account that started the install. sudo sets SUDO_USER. pkexec sets
# PKEXEC_UID and does not set SUDO_USER.
invoking_user() {
    local user_name=""
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        user_name=$SUDO_USER
    elif [[ -n "${PKEXEC_UID:-}" ]]; then
        user_name=$(getent passwd "$PKEXEC_UID" | cut -d: -f1)
    fi
    printf '%s' "$user_name"
}

invoking_home() {
    local user_name home_dir
    user_name=$(invoking_user)
    [[ -n "$user_name" ]] || return 0
    home_dir=$(getent passwd "$user_name" | cut -d: -f6)
    printf '%s' "$home_dir"
}

require_project_files() {
    [[ -f "$PROJECT_DIR/host-route" ]] || die "host-route is not next to install.sh"
    [[ -f "$PROJECT_DIR/hosts.txt" ]] || die "hosts.txt is not next to install.sh"
    [[ -f "$PROJECT_DIR/config" ]] || die "config is not next to install.sh"
    [[ -f "$PROJECT_DIR/host-route.service" ]] || die "host-route.service is not next to install.sh"
    [[ -f "$PROJECT_DIR/README.md" ]] || die "README.md is not next to install.sh"
}

# Last uncommented Defaults secure_path wins. sudoers.d is applied after
# /etc/sudoers when includedir is at the end of the main file, which is the
# usual layout.
effective_secure_path() {
    local files=() extra
    [[ -f /etc/sudoers ]] && files+=("/etc/sudoers")
    if [[ -d /etc/sudoers.d ]]; then
        for extra in /etc/sudoers.d/*; do
            [[ -f "$extra" ]] || continue
            files+=("$extra")
        done
    fi
    [[ ${#files[@]} -gt 0 ]] || return 0
    awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*Defaults[[:space:]].*secure_path="/ {
            line = $0
            sub(/^.*secure_path="/, "", line)
            sub(/".*$/, "", line)
            found = line
        }
        END { if (found != "") print found }
    ' "${files[@]}"
}

# Drop a symlink from the home-directory bin so the shell and sudo resolve
# the same installed command.
remove_user_symlink() {
    local home_dir link
    home_dir=$(invoking_home)
    [[ -n "$home_dir" ]] || return 0
    link="${home_dir}/.local/bin/host-route"
    if [[ -L "$link" ]]; then
        rm -f "$link"
        echo "removed ${link}"
    fi
}

# /usr/bin is on the sudo secure_path used here. /usr/local/bin is not, once
# the later Defaults line replaces the earlier one. Link only in that case,
# and only remove a symlink this installer created.
link_for_sudo() {
    local secure_path target
    secure_path=$(effective_secure_path || true)
    if [[ -z "$secure_path" ]]; then
        return 0
    fi
    case ":${secure_path}:" in
        *":${PREFIX}/bin:"*)
            if [[ -L "$SUDO_LINK" ]]; then
                target=$(readlink -f "$SUDO_LINK" || true)
                if [[ "$target" == "$BIN_PATH" ]]; then
                    rm -f "$SUDO_LINK"
                fi
            fi
            ;;
        *)
            ln -sfn "$BIN_PATH" "$SUDO_LINK"
            echo "linked ${SUDO_LINK} -> ${BIN_PATH}"
            echo "sudo secure_path does not include ${PREFIX}/bin (${secure_path})"
            ;;
    esac
}

# The packaged unit starts at boot as user sing-box and would load whatever
# is in /etc/sing-box. Leave it disabled when it is not already running.
# A service that is already active belongs to someone else.
quiesce_packaged_service() {
    systemctl cat sing-box.service >/dev/null 2>&1 || return 0
    if systemctl is-active --quiet sing-box.service; then
        echo "sing-box.service is already running; leaving that process alone"
        echo "host-route starts its own sing-box. Two tuns will conflict."
        return
    fi
    systemctl disable sing-box.service >/dev/null 2>&1 || true
    echo "left sing-box.service disabled; host-route.service supervises the process"
}

install_unit() {
    install -m 0644 "$PROJECT_DIR/host-route.service" "$UNIT_PATH"
    systemctl daemon-reload
    echo "installed ${UNIT_PATH}"
}

# Create /etc/host-route once. A later install leaves the host list and the
# connection name in place.
install_etc() {
    install -d -m 0755 "$SHARE_DIR"
    install -m 0644 "$PROJECT_DIR/hosts.txt" "${SHARE_DIR}/hosts.txt"
    install -m 0644 "$PROJECT_DIR/README.md" "${SHARE_DIR}/README.md"
    install -d -m 0755 "$ETC_DIR"
    if [[ -f "${ETC_DIR}/hosts.txt" ]]; then
        echo "kept existing ${ETC_DIR}/hosts.txt"
    else
        install -m 0644 "$PROJECT_DIR/hosts.txt" "${ETC_DIR}/hosts.txt"
    fi
    if [[ -f "${ETC_DIR}/config" ]]; then
        echo "kept existing ${ETC_DIR}/config"
    else
        install -m 0644 "$PROJECT_DIR/config" "${ETC_DIR}/config"
        echo "edit connection= in ${ETC_DIR}/config before starting"
    fi
}

cmd_install() {
    require_project_files
    require_commands
    install_etc
    install -d -m 0755 "${PREFIX}/bin"
    install -m 0755 "$PROJECT_DIR/host-route" "$BIN_PATH"
    echo "using $(sing-box version | head -n 1)"
    quiesce_packaged_service
    install_unit
    link_for_sudo
    remove_user_symlink
    echo "installed ${BIN_PATH}"
    echo "host list: ${ETC_DIR}/hosts.txt"
    echo "connection: ${ETC_DIR}/config"
    echo "next: sudo host-route start"
}

cmd_uninstall() {
    local purge=0 target
    if [[ "${1:-}" == "--purge" ]]; then
        purge=1
    elif [[ -n "${1:-}" ]]; then
        die "unknown uninstall option: $1"
    fi
    if [[ -x "$BIN_PATH" ]]; then
        "$BIN_PATH" stop || true
    fi
    if command -v systemctl >/dev/null 2>&1 && [[ -f "$UNIT_PATH" ]]; then
        systemctl disable --now "$NAME.service" >/dev/null 2>&1 || true
    fi
    rm -f "$UNIT_PATH" "$DISPATCHER_PATH"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload || true
    fi
    if [[ -L "$SUDO_LINK" ]]; then
        target=$(readlink -f "$SUDO_LINK" || true)
        if [[ "$target" == "$BIN_PATH" ]]; then
            rm -f "$SUDO_LINK"
        fi
    fi
    rm -f "$BIN_PATH"
    rm -rf "$SHARE_DIR"
    if [[ "$purge" -eq 1 ]]; then
        rm -rf "$ETC_DIR"
        echo "removed ${ETC_DIR}"
    else
        echo "left ${ETC_DIR} in place"
    fi
    echo "uninstalled"
    echo "sing-box was not removed"
}

main() {
    if [[ "$(id -u)" -ne 0 ]]; then
        exec sudo -- "$0" "$@"
    fi
    case "${1:-install}" in
        install)
            [[ $# -le 1 ]] || die "install takes no arguments"
            cmd_install
            ;;
        uninstall)
            shift
            cmd_uninstall "$@"
            ;;
        -h|--help|help)
            sed -n '2,17p' "$0"
            ;;
        *)
            die "unknown command: $1"
            ;;
    esac
}

main "$@"
