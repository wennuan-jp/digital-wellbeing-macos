# digital-wellbeing-macos (`lol-guard`)

A lightweight, native Swift 24/7 macOS background daemon for digital wellbeing and app-usage guardrails. It enforces per-app schedules (`hide`, `minimize`, `close_windows`, or `kill`) while optionally pausing enforcement when specific processes (such as an active game match) are running.

## Features

- **Ultra-lightweight 24/7**: Compiled native binary using `AppKit` and `libproc` (`proc_listallpids` / `proc_pidpath`) with minimal memory footprint and near-zero CPU when idle.
- **Event-driven + adaptive polling**: Subscribes to `NSWorkspace` launch/activate/terminate notifications and only polls at `activePollIntervalSeconds` while a target process is running.
- **Multi-app rules & flexible schedules**: Configure `allowedWindows` or `blockedWindows` per app, with optional weekday filters (`mon`–`sun`) and overnight ranges (e.g. `23:00` → `08:00`).
- **Context-aware exceptions**: Use `allowProcesses` to pause enforcement while a protected process is active (e.g., blocking `LeagueClientUx` lobby without interrupting an active `League of Legends` match).
- **Minimal permissions**: `hide` and `kill` require no special macOS permissions. `minimize` and `close_windows` use AppleScript and only prompt for Automation permission for the target app if used.
- **Auto-restarting & live reload**: Runs as a `launchd` user agent (`ProcessType: Background`, `KeepAlive: true`) and reloads edits to `~/.config/lol-guard/config.json` automatically.

## Build & Test

```bash
make
./build/lol-guard --status
./build/lol-guard --once --dry-run
```

Or run the built-in test target:

```bash
make test
```

### CLI Options

- `--config <path>`: Path to JSON config (default: `~/.config/lol-guard/config.json`)
- `--once`: Run a single check and exit
- `--dry-run`: Log actions without hiding, minimizing, closing windows, or terminating processes
- `--status`: Print current status and exit

## Install as a 24/7 `launchd` Service

```bash
./scripts/install.sh
```

This builds the binary, installs it to `~/.local/bin/lol-guard`, copies `config.example.json` to `~/.config/lol-guard/config.json` (if missing), and registers `~/Library/LaunchAgents/com.lolguard.agent.plist`.

To uninstall:

```bash
./scripts/uninstall.sh
```

## Configuration (`~/.config/lol-guard/config.json`)

See [`config.example.json`](config.example.json) for a full multi-rule example:

```json
{
  "rules": [
    {
      "name": "League of Legends",
      "mode": "hide",
      "alwaysBlock": false,
      "allowedWindows": [
        { "days": ["sat", "sun"], "start": "17:00", "end": "20:00" }
      ],
      "allowProcesses": ["League of Legends"],
      "targetProcesses": ["LeagueClientUx"]
    }
  ],
  "activePollIntervalSeconds": 0.5,
  "idleHeartbeatSeconds": 30.0,
  "logFile": "~/Library/Logs/lol-guard.log",
  "maxLogBytes": 1048576
}
```

### Rule Fields

- `name`: Display name used in logs and status output.
- `mode`: Enforcement action when blocked:
  - `"hide"` (default): Calls `NSRunningApplication.hide()` so the app stays hidden without stealing focus.
  - `"minimize"`: Minimizes open windows of the target app.
  - `"close_windows"`: Closes open windows of the target app.
  - `"kill"`: Terminates matching `targetProcesses` (and optional `alsoKillProcesses`).
- `alwaysBlock`: Set to `true` to enforce 24/7, or `false` to use `allowedWindows` / `blockedWindows`.
- `allowedWindows` / `blockedWindows`: Array of `{ "days": ["mon", ...], "start": "HH:mm", "end": "HH:mm" }` (`days` is optional; omitting it applies to every day).
- `allowProcesses`: Processes that pause enforcement for the rule while running.
- `targetProcesses`: Exact executable names or full-path substrings to match.
