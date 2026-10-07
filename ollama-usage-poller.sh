#!/usr/bin/env bash
# ollama-usage-poller.sh — Polls the Ollama cloud balance API and writes a
# claude-hud external-usage snapshot.
#
# The quota lives in https://ollama.com/api/balance since the 2026-08 pricing
# change: /api/usage now carries only per-request metrics (request counts, USD,
# tokens) and no longer exposes limit windows. The snapshot format still
# matches claude-hud's `externalUsagePath` contract (see src/external-usage.ts):
# five_hour / seven_day used-percentage with an updated_at timestamp.
# claude-hud reads it as a fallback when stdin carries no rate_limits (i.e.
# when Claude Code runs against Ollama).
#
# Included-balance shapes (docs.ollama.com/api/balance — `included` is a oneOf):
#   - Legacy plans: `session` / `weekly` objects with `remaining_percent`
#     (0-100, quota REMAINING, not consumed — convert with used = 100 − rest)
#     and `resets_at`. Maps 1:1 to the snapshot's five_hour / seven_day bars.
#   - Standard plans: `balance_usd` / `allowance_usd` / `period` monthly
#     credits. No 5h/weekly windows exist, so the bars are written as null and
#     only the balance label is populated.
# `purchased.balance_usd` (remaining unexpired purchased credits) applies to
# both shapes and feeds the snapshot's `balance_label`.
#
# Usage:
#   ollama-usage-poller.sh --once   # fetch once and exit (launchd mode)
#   ollama-usage-poller.sh          # daemon mode: poll forever
#
# Env:
#   OLLAMA_API_KEY                  # explicit key (takes precedence)
#   OLLAMA_BALANCE_URL              # default: https://ollama.com/api/balance (test seam)
#   OLLAMA_USAGE_SNAPSHOT_PATH      # default: ~/.claude/plugins/claude-hud/ollama-usage.json
#   OLLAMA_USAGE_POLL_INTERVAL      # daemon mode only, seconds (default 120)
set -euo pipefail

# Force the C locale so awk's printf uses '.' as the decimal separator
# regardless of the system locale (e.g. fr_FR uses ',').
export LC_ALL=C

BALANCE_URL="${OLLAMA_BALANCE_URL:-https://ollama.com/api/balance}"
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

# Ollama cloud usage windows are fixed and epoch-aligned (maintainer
# rick-github, ollama/ollama#12532); the API returns resets_at, this only
# stands in when the field is absent:
#   session: 5h blocks, reset at the next multiple of 18000s since epoch
#   weekly:  7d blocks shifted by 4 days, reset at the next multiple of
#            604800s since epoch (Monday 00:00 UTC)
epoch_fallback_reset() {
  local epoch window shift
  epoch="$(date +%s)"
  case "$1" in
    session) window=18000; shift_count=0 ;;
    weekly)  window=604800; shift_count=345600 ;;
    *) return ;;
  esac
  epoch_to_iso "$((epoch + (window - ((epoch - shift_count) % window))))"
}

fetch_and_write() {
  local balance
  balance="$(curl -fsS -m 15 -H "Authorization: Bearer $API_KEY" "$BALANCE_URL")" || return 1

  # remaining_percent is the quota REMAINING (75 means 75% left); the snapshot
  # wants used_percentage, hence the 100 − conversion, clamped to [0, 100].
  local session_remaining weekly_remaining
  session_remaining="$(printf '%s' "$balance" | jq -r '.included.session.remaining_percent // empty')"
  weekly_remaining="$(printf '%s' "$balance" | jq -r '.included.weekly.remaining_percent // empty')"
  local session_pct_json="null" weekly_pct_json="null"

  if [[ -n "$session_remaining" ]]; then
    session_pct_json="$(awk -v r="$session_remaining" 'BEGIN{u=100-r; u=u<0?0:u>100?100:u; printf "%.2f", u}')"
  fi
  if [[ -n "$weekly_remaining" ]]; then
    weekly_pct_json="$(awk -v r="$weekly_remaining" 'BEGIN{u=100-r; u=u<0?0:u>100?100:u; printf "%.2f", u}')"
  fi

  # Preferred: the API-provided reset timestamps; epoch-aligned math only as a
  # stand-in when the field is absent while the window is present.
  local session_reset weekly_reset
  session_reset="$(printf '%s' "$balance" | jq -r '.included.session.resets_at // empty')"
  weekly_reset="$(printf '%s' "$balance" | jq -r '.included.weekly.resets_at // empty')"
  if [[ -n "$session_remaining" && -z "$session_reset" ]]; then
    session_reset="$(epoch_fallback_reset session)"
  fi
  if [[ -n "$weekly_remaining" && -z "$weekly_reset" ]]; then
    weekly_reset="$(epoch_fallback_reset weekly)"
  fi

  # Balance labels: `included` differs by plan shape and `purchased` is the
  # remaining unexpired prepaid credits (rendered verbatim by the HUD at the
  # end of the usage line via the snapshot's balance_label field).
  local included_usd allowance_usd purchased cost_label
  included_usd="$(printf '%s' "$balance" | jq -r '.included.balance_usd // empty')"
  allowance_usd="$(printf '%s' "$balance" | jq -r '.included.allowance_usd // empty')"
  purchased="$(printf '%s' "$balance" | jq -r '.purchased.balance_usd // empty')"
  cost_label=""
  if [[ -n "$allowance_usd" && -n "$included_usd" ]]; then
    cost_label="$(awk -v i="$included_usd" -v a="$allowance_usd" 'BEGIN{printf "Cr: $%.2f/$%.2f", i, a}')"
    if [[ -n "$purchased" ]]; then
      cost_label="$cost_label$(awk -v c="$purchased" 'BEGIN{printf " +$%.2f", c}')"
    fi
  elif [[ -n "$purchased" ]]; then
    cost_label="$(awk -v c="$purchased" 'BEGIN{printf "Xtr: $%.2f left", c}')"
  fi

  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  mkdir -p "$(dirname "$SNAPSHOT_PATH")"
  local tmp
  tmp="$(mktemp "$SNAPSHOT_PATH.XXXXXX")"
  # jq (not a heredoc) builds the snapshot so the API-provided strings can
  # never produce invalid JSON, and absent windows land as literal nulls.
  jq -n \
    --arg now "$now" \
    --arg sp "$session_pct_json" --arg sr "$session_reset" \
    --arg wp "$weekly_pct_json" --arg wr "$weekly_reset" \
    --arg lbl "$cost_label" \
    '{
      updated_at: $now,
      five_hour: {
        used_percentage: (if $sp == "null" then null else ($sp | tonumber) end),
        resets_at: (if $sr == "" then null else $sr end)
      },
      seven_day: {
        used_percentage: (if $wp == "null" then null else ($wp | tonumber) end),
        resets_at: (if $wr == "" then null else $wr end)
      },
      balance_label: $lbl
    }' > "$tmp"

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