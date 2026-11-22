#!/usr/bin/env bash
set -euo pipefail

UID_VAL="$(id -u)"
PLIST_PATH="${HOME}/Library/LaunchAgents/com.lolguard.agent.plist"
BIN_PATH="${HOME}/.local/bin/lol-guard"

launchctl bootout "gui/${UID_VAL}/com.lolguard.agent" 2>/dev/null || true
rm -f "${PLIST_PATH}" "${BIN_PATH}"

echo "Uninstalled com.lolguard.agent (config preserved at ~/.config/lol-guard/config.json)."
