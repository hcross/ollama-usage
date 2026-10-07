# ollama-usage

Polls the [Ollama cloud](https://ollama.com) balance API and writes a
snapshot consumed by [claude-hud](https://github.com/hcross/claude-hud) as an
external usage sidecar, so the HUD can display 5h / weekly quota bars and the
unused prepaid credits (`Xtr: $3.39 left`) even when Claude Code runs against
Ollama (where the native `rate_limits` payload is absent).

## What it does

`ollama-usage-poller.sh` fetches `https://ollama.com/api/balance` with your API
key and writes a snapshot to
`~/.claude/plugins/claude-hud/ollama-usage.json`:

```json
{
  "updated_at": "2026-10-07T21:53:55Z",
  "five_hour": { "used_percentage": 21.11, "resets_at": "2026-10-07T23:00:00Z" },
  "seven_day": { "used_percentage": 14.47, "resets_at": "2026-10-12T00:00:00Z" },
  "balance_label": "Xtr: $3.39 left"
}
```

The included-credit windows come from the balance endpoint's `included`
shape (docs: [/api/balance](https://docs.ollama.com/api/balance)). Legacy
plans return `session` / `weekly` with `remaining_percent` — quota still
remaining — and `resets_at`; the poller converts with
`used_percentage = 100 − remaining_percent` and stores the API-provided
`resets_at`. Standard plans (monthly credits from the 2026-08 transparent
pricing change) have no 5h/weekly windows, so the bars are written as `null`
and only the balance label is populated:

- `Xtr: $N left` — legacy plans: remaining unexpired purchased credits
- `Cr: $X/$Y +$N` — standard plans: included credits remaining over the
  allowance for the current period, plus purchased credits

> The quota endpoint changed twice in 2026: `/api/usage` served
> `limits.session` / `limits.weekly` fractions until the pricing change, then
> moved to per-request metrics only with the percentages and reset timestamps
> moved to `/api/balance`. Against the old response shape `jq`'s `// 0`
> fallback masked the missing fields and wrote 0 bars silently — the reason
> this poller reads the balance endpoint instead.

The format matches claude-hud's `display.externalUsagePath` contract — see the
[claude-hud README, external usage section](https://github.com/hcross/claude-hud#external-usage-snapshot-fallback--balance_label).

A scheduler runs the poller every 120 seconds:

- **Linux** — systemd user service + timer
- **macOS** — launchd LaunchAgent

## Install

```sh
git clone https://github.com/hcross/ollama-usage.git
cd ollama-usage
./install.sh
```

The script verifies dependencies (`jq`, `curl`), checks that an API key is
reachable, installs the platform scheduler, and runs one poll as a smoke test.

Requirements:

- `jq`, `curl`
- An Ollama cloud API key, either:
  - exported as `OLLAMA_API_KEY`, or
  - present as `~/.ollama/<name>.api.key` (first file found wins)

The key is never stored, installed, or transmitted anywhere by this project —
the poller reads it at runtime only.

## Manual usage

```sh
./ollama-usage-poller.sh --once   # fetch once and exit
./ollama-usage-poller.sh          # daemon mode: poll forever
```

Environment overrides:

| Variable | Default | Purpose |
|---|---|---|
| `OLLAMA_API_KEY` | — | Explicit API key (takes precedence over key files) |
| `OLLAMA_BALANCE_URL` | `https://ollama.com/api/balance` | Balance endpoint override (test seam; serve a fixture to exercise the standard-plan shape) |
| `OLLAMA_USAGE_SNAPSHOT_PATH` | `~/.claude/plugins/claude-hud/ollama-usage.json` | Snapshot output path |
| `OLLAMA_USAGE_POLL_INTERVAL` | `120` | Daemon-mode poll interval (seconds) |

## claude-hud configuration

Point claude-hud at the snapshot in `~/.claude/plugins/claude-hud/config.json`:

```json
{
  "display": {
    "externalUsagePath": "/home/YOU/.claude/plugins/claude-hud/ollama-usage.json",
    "externalBalanceLabelMode": "ollama-cloud"
  }
}
```

`externalBalanceLabelMode: "ollama-cloud"` keeps the `balance_label` scoped to
Ollama cloud sessions (`:cloud` models) so it never leaks into native Anthropic
sessions sharing the same config directory. The path must be absolute.

On a headless Linux machine, run `sudo loginctl enable-linger $USER` so the
user timer keeps firing without an active login session.

## License

MIT — see [LICENSE](LICENSE).