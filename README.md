# ollama-usage

Polls the [Ollama cloud](https://ollama.com) usage API and writes a
snapshot consumed by [claude-hud](https://github.com/hcross/claude-hud) as an
external usage sidecar, so the HUD can display 5h / weekly quota bars and the
extra-usage balance (`Xtr: $0.00/4wk`) even when Claude Code runs against
Ollama (where the native `rate_limits` payload is absent).

## What it does

`ollama-usage-poller.sh` fetches `https://ollama.com/api/usage` with your API
key and writes a snapshot to
`~/.claude/plugins/claude-hud/ollama-usage.json`:

```json
{
  "updated_at": "2026-09-17T09:51:16Z",
  "five_hour": { "used_percentage": 17.0, "resets_at": "2026-09-17T13:00:00Z" },
  "seven_day": { "used_percentage": 37.7, "resets_at": "2026-09-21T00:00:00Z" },
  "balance_label": "Xtr: $0.00/4wk"
}
```

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