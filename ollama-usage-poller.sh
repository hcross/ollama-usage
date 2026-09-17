#!/usr/bin/env bash
# ollama-usage-poller.sh — Polls the Ollama cloud usage API and writes a
# claude-hud external-usage snapshot.
#
# The snapshot format matches claude-hud's `externalUsagePath` contract
# (see src/external-usage.ts): five_hour / seven_day percentages with an
# updated_at timestamp. claude-hud reads it as a fallback when stdin carries
# no rate_limits (i.e. when Claude Code runs against Ollama).
#
# Usage:
#   ollama-usage-poller.sh --once   # fetch once and exit (launchd mode)
#   ollama-usage-poller.sh          # daemon mode: poll forever
#
# Env:
#   OLLAMA_API_KEY                  # explicit key (takes precedence)
#   OLLAMA_USAGE_SNAPSHOT_PATH      # default: ~/.claude/plugins/claude-hud/ollama-usage.json
#   OLLAMA_USAGE_POLL_INTERVAL      # daemon mode only, seconds (default 120)
set -euo pipefail

# Force the C locale so awk's printf uses '.' as the decimal separator
# regardless of the system locale (e.g. fr_FR uses ',').
export LC_ALL=C

API_URL="https://ollama.com/api/usage"
SNAPSHOT_PATH="${OLLAMA_USAGE_SNAPSHOT_PATH:-$HOME/.claude/plugins/claude-hud/ollama-usage.json}"
POLL_INTERVAL="${OLLAMA_USAGE_POLL_INTERVAL:-120}"

# Resolve the API key: explicit env var first, then known key files.
API_KEY="${OLLAMA_API_KEY:-}"
if [[ -z "$API_KEY" ]]; then
  for f in "$HOME/.ollama/ff4-port.api.key" "$HOME/.ollama/r-brain.api.key"; do
    if [[ -f "$f" ]]; then
      API_KEY="$(cat "$f")"
      break
    fi
  done
fi
if [[ -z "$API_KEY" ]]; then
  echo "ollama-usage: no API key found (set OLLAMA_API_KEY or add a key to ~/.ollama/*.api.key)" >&2
  exit 1
fi

# Portable epoch → ISO-8601: BSD date uses -r <epoch>, GNU date uses -d @<epoch>.
if date -u -r 0 +%s >/dev/null 2>&1; then
  epoch_to_iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
else
  epoch_to_iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
fi

fetch_and_write() {
  local resp
  resp="$(curl -fsS -m 15 -H "Authorization: Bearer $API_KEY" "$API_URL")" || return 1

  local session weekly
  session="$(printf '%s' "$resp" | jq -r '.limits.session.usage // 0')"
  weekly="$(printf '%s' "$resp" | jq -r '.limits.weekly.usage // 0')"

  # The API returns fractional usage (0.504 = 50.4%); claude-hud expects a
  # 0-100 percentage.
  local session_pct weekly_pct
  session_pct="$(awk -v v="$session" 'BEGIN{printf "%.1f", v*100}')"
  weekly_pct="$(awk -v v="$weekly" 'BEGIN{printf "%.1f", v*100}')"

  # activity.cost = cumulative extra-usage cost over a rolling 4-week window
  # (drawn from the extra usage balance once plan limits are exhausted).
  # Rendered by claude-hud via the snapshot's balance_label field.
  local cost cost_label
  cost="$(printf '%s' "$resp" | jq -r '.activity.cost // ""')"
  if [[ -n "$cost" ]]; then
    cost_label="$(awk -v c="$cost" 'BEGIN{printf "Xtr: $%.2f/4wk", c}')"
  else
    cost_label=""
  fi

  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Ollama cloud usage windows are fixed and epoch-aligned (maintainer
  # rick-github, ollama/ollama#12532):
  #   session: 5h blocks, reset at the next multiple of 18000s since epoch
  #   weekly:  7d blocks shifted by 4 days, reset at the next multiple of
  #            604800s since epoch (Monday 00:00 UTC)
  local epoch session_reset weekly_reset
  epoch="$(date +%s)"
  session_reset="$((epoch + (18000 - (epoch % 18000))))"
  weekly_reset="$((epoch + (604800 - ((epoch - 345600) % 604800))))"

  local session_reset_iso weekly_reset_iso
  session_reset_iso="$(epoch_to_iso "$session_reset")"
  weekly_reset_iso="$(epoch_to_iso "$weekly_reset")"

  mkdir -p "$(dirname "$SNAPSHOT_PATH")"
  local tmp
  tmp="$(mktemp "$SNAPSHOT_PATH.XXXXXX")"
  cat > "$tmp" <<EOF
{
  "updated_at": "$now",
  "five_hour": { "used_percentage": $session_pct, "resets_at": "$session_reset_iso" },
  "seven_day": { "used_percentage": $weekly_pct, "resets_at": "$weekly_reset_iso" },
  "balance_label": "$cost_label"
}
EOF
  mv "$tmp" "$SNAPSHOT_PATH"
  chmod 600 "$SNAPSHOT_PATH"
}

if [[ "${1:-}" == "--once" ]]; then
  fetch_and_write
  exit $?
fi

while true; do
  fetch_and_write || true
  sleep "$POLL_INTERVAL"
done
