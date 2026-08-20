#!/bin/bash

set -u

C_RESET="\033[0m"
C_BOLD="\033[1m"
C_GREEN="\033[32m"
C_RED="\033[31m"
C_YELLOW="\033[33m"
C_CYAN="\033[36m"
C_GRAY="\033[90m"

get_time() {
    local s=""
    local mot="Socrate Executor"
    local couleurs=("255;235;100" "255;215;0" "255;195;0" "230;170;0" "210;140;0" "190;120;0" "170;100;0")
    for ((i=0; i<${#mot}; i++)); do
        s+="\033[38;2;${couleurs[$i]}m${mot:$i:1}"
    done
    s+="${C_RESET}"
    printf "%b" "${s}${C_GRAY}::${C_RESET}${C_GREEN}[$(date +%H:%M:%S)]${C_RESET}"
}

log() { printf "%b %b\n" "$(get_time)" "$1"; }

die() {
    spinner_stop "fail" "$1"
    exit 1
}

banner() {
    local line="────────────────────────────────────────────"
    echo ""
    printf "${C_GRAY}%s${C_RESET}\n" "$line"
    printf "  %b  ${C_BOLD}Installer${C_RESET}\n" "$(printf "\033[38;2;255;215;0m%s\033[0m" "Socrate")"
    printf "${C_GRAY}%s${C_RESET}\n" "$line"
    echo ""
}

SPIN_FRAMES=("⣾" "⣽" "⣻" "⢿" "⡿" "⣟" "⣯" "⣷")
SPINNER_PID=""
SPINNER_MSG=""

spinner_start() {
    SPINNER_MSG="$1"
    printf "\033[?25l\033[?7l"
    (
        local i=0
        while true; do
            local frame="${SPIN_FRAMES[$((i % ${#SPIN_FRAMES[@]}))]}"
            printf "\r\033[2K%b ${C_CYAN}%s${C_RESET}  %s" "$(get_time)" "$frame" "$SPINNER_MSG"
            i=$((i+1))
            sleep 0.08
        done
    ) &
    SPINNER_PID=$!
    disown "$SPINNER_PID" 2>/dev/null || true
}

spinner_stop() {
    local status="${1:-ok}"
    local msg="${2:-$SPINNER_MSG}"
    if [[ -n "$SPINNER_PID" ]] && kill -0 "$SPINNER_PID" 2>/dev/null; then
        kill "$SPINNER_PID" 2>/dev/null
        wait "$SPINNER_PID" 2>/dev/null || true
    fi
    SPINNER_PID=""
    printf "\r\033[2K"
    case "$status" in
        ok)   printf "%b ${C_GREEN}✔${C_RESET}  %b\n" "$(get_time)" "$msg" ;;
        fail) printf "%b ${C_RED}✖${C_RESET}  %b\n"   "$(get_time)" "$msg" ;;
        warn) printf "%b ${C_YELLOW}!${C_RESET}  %b\n" "$(get_time)" "$msg" ;;
        *)    printf "%b    %b\n" "$(get_time)" "$msg" ;;
    esac
    printf "\033[?7h\033[?25h"
}

download_with_progress() {
    local url="$1"
    local out="$2"
    local label="$3"
    local bar_width=20

    local total
    total=$(curl -sIL -m 10 "$url" | awk 'BEGIN{IGNORECASE=1} /^content-length:/ {gsub(/\r/,""); v=$2} END{print v+0}')
    [[ -z "$total" || "$total" == "0" ]] && total=0

    curl -fL -s "$url" -o "$out" &
    local pid=$!

    printf "\033[?25l\033[?7l"

    local i=0
    local min_loops=5
    while kill -0 "$pid" 2>/dev/null || (( i < min_loops )); do
        local cur=0
        [[ -f "$out" ]] && cur=$(stat -f%z "$out" 2>/dev/null || echo 0)

        local pct="0.0" filled=0
        if [[ "$total" -gt 0 ]]; then
            pct=$(awk -v c="$cur" -v t="$total" 'BEGIN{p=(c/t)*100; if(p>100)p=100; printf "%.1f", p}')
            filled=$(awk -v c="$cur" -v t="$total" -v w="$bar_width" 'BEGIN{f=int((c/t)*w); if(f>w)f=w; print f}')
        fi

        local bar=""
        for ((j=0; j<filled; j++));        do bar+="━"; done
        for ((j=filled; j<bar_width; j++)); do bar+="─"; done

        local frame="${SPIN_FRAMES[$((i % ${#SPIN_FRAMES[@]}))]}"
        printf "\r\033[2K%b ${C_CYAN}%s${C_RESET} %s ${C_GREEN}%s${C_RESET} ${C_BOLD}%5s%%${C_RESET}" \
               "$(get_time)" "$frame" "$label" "$bar" "$pct"
        i=$((i+1))
        sleep 0.1

        if ! kill -0 "$pid" 2>/dev/null && (( i >= min_loops )); then
            break
        fi
    done
    wait "$pid" 2>/dev/null; local rc=$?

    printf "\r\033[2K"
    if [[ $rc -eq 0 ]]; then
        local bar=""
        for ((j=0; j<bar_width; j++)); do bar+="━"; done
        printf "%b ${C_GREEN}✔${C_RESET} %s ${C_GREEN}%s${C_RESET} ${C_BOLD}100.0%%${C_RESET}\n" \
               "$(get_time)" "$label" "$bar"
    else
        printf "%b ${C_RED}✖${C_RESET} %s failed\n" "$(get_time)" "$label"
    fi

    printf "\033[?7h\033[?25h"
    return $rc
}

detect_arch() {
    local os arch
    os=$(uname -s); arch=$(uname -m)
    if [[ "$os" == "Darwin" ]]; then
        if [[ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" == "1" ]]; then
            arch="arm64"
        fi
    fi
    case "$arch" in
        arm64|aarch64) echo "arm" ;;
        x86_64|amd64)  echo "intel" ;;
        *)             echo "unknown" ;;
    esac
}

WORKDIR="$(mktemp -d -t socrate)"
DMG_PATH="${WORKDIR}/Socrate.dmg"
MOUNT_PATH=""
SUDO_KEEPALIVE_PID=""

cleanup() {
    [[ -n "$SPINNER_PID" ]] && kill "$SPINNER_PID" 2>/dev/null
    printf "\033[?7h\033[?25h"
    [ -n "${MOUNT_PATH}" ] && [ -d "${MOUNT_PATH}" ] && hdiutil detach "${MOUNT_PATH}" -quiet 2>/dev/null
    [ -n "${SUDO_KEEPALIVE_PID}" ] && kill "${SUDO_KEEPALIVE_PID}" 2>/dev/null
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT INT TERM

killall -9 Roblox       2>/dev/null
killall -9 RobloxPlayer 2>/dev/null
killall -9 Socrate      2>/dev/null

banner

spinner_start "checking versions..."
MAC_VERSION=$(curl -fsS -m 8 -H "User-Agent: WEAO-3PService" "https://weao.xyz/api/versions/current" | jq -r '.Mac' 2>/dev/null)
UPDATED_FOR_ROBLOX_V=$(curl -fsS -m 8 "https://raw.githubusercontent.com/pleglou26-oss/not_default_socrate_repo/main/status.json" | jq -r '.Socrate.Updated_for_roblox_v' 2>/dev/null)
[[ -z "$MAC_VERSION" || "$MAC_VERSION" == "null" ]] && MAC_VERSION="unknown"
[[ -z "$UPDATED_FOR_ROBLOX_V" || "$UPDATED_FOR_ROBLOX_V" == "null" ]] && UPDATED_FOR_ROBLOX_V="unknown"
spinner_stop ok "versions fetched"

log "latest roblox version : ${C_BOLD}${MAC_VERSION}${C_RESET}"
log "socrate updated for   : ${C_BOLD}${UPDATED_FOR_ROBLOX_V}${C_RESET}"

if [[ "$MAC_VERSION" != "unknown" && "$UPDATED_FOR_ROBLOX_V" != "unknown" && "$MAC_VERSION" != "$UPDATED_FOR_ROBLOX_V" ]]; then
    echo ""
    printf "  ${C_YELLOW}⚠  Socrate is OUTDATED${C_RESET}\n"
    printf "  ${C_GRAY}Roblox is on ${MAC_VERSION} but Socrate supports ${UPDATED_FOR_ROBLOX_V}.${C_RESET}\n"
    printf "  ${C_GRAY}It may not work until an update is released.${C_RESET}\n"
    echo ""
    printf "%b " "$(get_time)"
    read -r -p "Continue anyway? [y/N]: " cont </dev/tty
    case "$cont" in
        y|Y|yes|YES) log "continuing..." ;;
        *) die "aborted by user" ;;
    esac
else
    log "${C_GREEN}socrate is up to date${C_RESET}"
fi

echo ""
log "${C_CYAN}admin access required${C_RESET} — enter your mac password if asked"
sudo -v || die "admin permission denied"
(
    while true; do
        sudo -n true
        sleep 30
        kill -0 "$$" 2>/dev/null || exit
    done
) &
SUDO_KEEPALIVE_PID=$!
disown "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
log "${C_GREEN}admin granted${C_RESET}"

DMG_URL="https://github.com/pleglou26-oss/not_default_socrate_repo/blob/main/Socrate.dmg?raw=true"

download_with_progress "${DMG_URL}" "${DMG_PATH}" "downloading socrate" || die "failed downloading dmg"
[ -f "${DMG_PATH}" ] || die "missing dmg"

spinner_start "mounting dmg..."
MOUNT_PATH="$(hdiutil attach "${DMG_PATH}" -nobrowse -noautoopen 2>/dev/null | awk -F'\t' '/\/Volumes\// {print $NF; exit}')"
[ -n "${MOUNT_PATH}" ] || { spinner_stop fail "mount failed"; exit 1; }
spinner_stop ok "dmg mounted"

APP_NAME="$(ls "${MOUNT_PATH}" | grep '\.app$' | head -n 1)"
[ -n "${APP_NAME}" ] || die "no app found in dmg"

TARGET_PATH="/Applications/${APP_NAME}"

spinner_start "installing ${APP_NAME}..."
sudo -n rm -rf "${TARGET_PATH}"
sudo -n cp -R "${MOUNT_PATH}/${APP_NAME}" "/Applications/" || { spinner_stop fail "install failed"; exit 1; }
hdiutil detach "${MOUNT_PATH}" -quiet
MOUNT_PATH=""
spinner_stop ok "${APP_NAME} installed"

spinner_start "removing quarantine..."
sudo -n xattr -rd com.apple.quarantine "${TARGET_PATH}" 2>/dev/null || true
sudo -n xattr -cr "${TARGET_PATH}"
spinner_stop ok "quarantine removed"

spinner_start "launching socrate..."
open "${TARGET_PATH}"
spinner_stop ok "socrate launched"

echo ""
printf "  ${C_GREEN}✔  All done — enjoy Socrate${C_RESET}\n"
echo ""
