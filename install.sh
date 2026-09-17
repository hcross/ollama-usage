#!/usr/bin/env bash
# install.sh — Install the ollama-usage poller as a scheduled job.
#
# - Linux: systemd user service + timer (poll every 120s)
# - macOS: launchd LaunchAgent (poll every 120s)
#
# Also verifies dependencies and the Ollama API key. The key itself is never
# installed or stored by this script — it must already exist in ~/.ollama/
# or be provided via the OLLAMA_API_KEY environment variable.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLL_INTERVAL=120
SNAPSHOT_DIR="${HOME}/.claude/plugins/claude-hud"

info()  { printf '%s\n' "install: $*"; }
fail()  { printf '%s\n' "install: ERROR: $*" >&2; exit 1; }

# --- Dependencies -------------------------------------------------------------

for cmd in jq curl; do
  command -v "$cmd" >/dev/null 2>&1 || fail "$cmd is required but not found in PATH"
done
info "dependencies OK (jq, curl)"

# --- Ollama API key -----------------------------------------------------------

if [[ -n "${OLLAMA_API_KEY:-}" ]]; then
  info "OLLAMA_API_KEY is set in the environment"
elif compgen -G "${HOME}/.ollama/*.api.key" >/dev/null; then
  info "API key found in ~/.ollama/"
else
  fail "no API key: set OLLAMA_API_KEY or add a key file to ~/.ollama/<name>.api.key"
fi

# --- Snapshot directory -------------------------------------------------------

mkdir -p "$SNAPSHOT_DIR"

# --- Platform-specific scheduling --------------------------------------------

install_systemd() {
  local unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  mkdir -p "$unit_dir"

  cat > "$unit_dir/ollama-usage.service" <<EOF
[Unit]
Description=Ollama cloud usage poller (claude-hud sidecar)

[Service]
Type=oneshot
ExecStart=${SCRIPT_DIR}/ollama-usage-poller.sh --once
EOF

  cat > "$unit_dir/ollama-usage.timer" <<EOF
[Unit]
Description=Poll Ollama cloud usage every ${POLL_INTERVAL}s

[Timer]
OnBootSec=30s
OnUnitActiveSec=${POLL_INTERVAL}s

[Install]
WantedBy=timers.target
EOF

  systemctl --user daemon-reload
  systemctl --user enable --now ollama-usage.timer
  info "systemd user timer installed and started (ollama-usage.timer)"

  # Headless machines: make sure user units keep running without a login session.
  if ! loginctl show-user "$USER" 2>/dev/null | grep -q '^Linger=yes'; then
    info "hint: on a headless machine, run 'sudo loginctl enable-linger $USER' so the timer survives logout"
  fi
}

install_launchd() {
  local plist="${HOME}/Library/LaunchAgents/com.hoanicross.ollama-usage.plist"
  mkdir -p "$(dirname "$plist")"

  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.hoanicross.ollama-usage</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${SCRIPT_DIR}/ollama-usage-poller.sh</string>
    <string>--once</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>${POLL_INTERVAL}</integer>
  <key>StandardOutPath</key>
  <string>/tmp/ollama-usage.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/ollama-usage.log</string>
</dict>
</plist>
EOF

  launchctl unload "$plist" 2>/dev/null || true
  launchctl load "$plist"
  info "LaunchAgent installed and loaded (${plist})"
}

case "$(uname -s)" in
  Linux)  install_systemd ;;
  Darwin) install_launchd ;;
  *)      fail "unsupported platform: only Linux (systemd) and macOS (launchd) are supported" ;;
esac

# --- Smoke test ---------------------------------------------------------------

info "running one poll to verify the setup..."
"$SCRIPT_DIR/ollama-usage-poller.sh" --once
info "snapshot written to ${SNAPSHOT_DIR}/ollama-usage.json"
info "done — claude-hud will pick it up on its next statusline refresh"