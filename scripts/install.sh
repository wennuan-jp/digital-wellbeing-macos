#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

BIN_DIR="${HOME}/.local/bin"
BIN_PATH="${BIN_DIR}/lol-guard"
CONFIG_DIR="${HOME}/.config/lol-guard"
CONFIG_PATH="${CONFIG_DIR}/config.json"
LAUNCH_AGENTS_DIR="${HOME}/Library/LaunchAgents"
PLIST_PATH="${LAUNCH_AGENTS_DIR}/com.lolguard.agent.plist"
LOG_DIR="${HOME}/Library/Logs"

echo "Building lol-guard..."
make -C "${PROJECT_DIR}"

mkdir -p "${BIN_DIR}" "${CONFIG_DIR}" "${LAUNCH_AGENTS_DIR}" "${LOG_DIR}"
cp "${PROJECT_DIR}/build/lol-guard" "${BIN_PATH}"
chmod +x "${BIN_PATH}"

if [[ ! -f "${CONFIG_PATH}" ]]; then
    cp "${PROJECT_DIR}/config.example.json" "${CONFIG_PATH}"
    echo "Created default config at ${CONFIG_PATH}"
else
    echo "Keeping existing config at ${CONFIG_PATH}"
fi

sed -e "s|__BIN_PATH__|${BIN_PATH}|g" \
    -e "s|__CONFIG_PATH__|${CONFIG_PATH}|g" \
    -e "s|__HOME__|${HOME}|g" \
    "${PROJECT_DIR}/com.lolguard.agent.plist.template" > "${PLIST_PATH}"

UID_VAL="$(id -u)"
launchctl bootout "gui/${UID_VAL}/com.lolguard.agent" 2>/dev/null || true
sleep 0.5
launchctl bootstrap "gui/${UID_VAL}" "${PLIST_PATH}"
launchctl kickstart -k "gui/${UID_VAL}/com.lolguard.agent"

echo ""
echo "Installed and started com.lolguard.agent!"
echo "  Binary: ${BIN_PATH}"
echo "  Config: ${CONFIG_PATH}"
echo "  Plist:  ${PLIST_PATH}"
echo "  Logs:   ${LOG_DIR}/lol-guard.log"
