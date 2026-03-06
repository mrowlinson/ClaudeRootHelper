# Claude Root Helper

A lightweight macOS app that gives Claude Code (or any CLI tool) a way to run commands as root without needing `sudo` in the terminal.

Claude Code restricts direct use of `sudo`. This helper runs a small root-privileged server in the background, authenticated via macOS's native admin password prompt. A companion CLI tool (`claude-root-cmd`) sends commands to the server and returns the result. Configurable allow/block command filters can be edited live in the app and take effect immediately — no restart required.

Launch the app when you need root access, quit it when you're done.

## How it works

1. **ClaudeRootHelper.app** — a Swift/Cocoa GUI app. On launch it uses `osascript` to start a root-privileged server (itself, with `--server`) via the standard macOS admin password dialog.
2. **Server mode** — the same binary runs as root, listening on a Unix domain socket at `/var/run/claude-root-helper.sock`. Executes commands and returns stdout/stderr/exit code.
3. **claude-root-cmd** — a compiled Swift CLI client installed to `/usr/local/bin/`. Sends a command to the server and prints the result.

When you quit the app, a watchdog in the server detects the app is gone and shuts itself down within seconds.

## Security

- **Peer credential verification** — the server checks the UID of every connecting process using macOS `LOCAL_PEERCRED`. Only the user who launched the app (and root) can send commands. Other users on the machine are rejected.
- **PID file in user home** — the app PID file is stored at `~/.claude-root-helper.pid`, not in world-writable `/tmp`, preventing symlink/race attacks.
- **Auto-shutdown** — the server watchdog exits automatically when the app quits, so the root server doesn't linger.
- **Socket permissions** — the socket is `0660` owned by `root:staff`, plus the UID check above.

### Command Filters

The app includes a configurable command filter with both an **allowlist** and a **blocklist**, active simultaneously:

- **Allowed Commands** — if any entries are present, the first word of the command must match one of them. Commands not on the list are rejected.
- **Blocked Commands** — if any entry appears as a substring anywhere in the command, it's rejected.

Click **"Command Filters"** at the bottom of the app window to expand the filter panel with two side-by-side editors. Changes are saved automatically after you stop typing and pushed to the running server in real time — no restart needed.

Filters are stored in `~/.claude-root-helper-filters.json`:

```json
{
  "allow": ["brew", "launchctl", "cat", "ls"],
  "block": ["rm -rf /", "shutdown", "reboot", "mkfs", "dd"]
}
```

If the config file doesn't exist or both lists are empty, no filtering is applied.

### Caveats

- **Without filters configured**, this is an unrestricted root shell for the authenticated user. Configure allowlist/blocklist rules for additional safety.
- Intended for **single-user development machines** during active use. Do not leave it running unattended on a shared system.

## Build

```bash
./build.sh
```

Requires Xcode command-line tools (`swiftc`). Produces `ClaudeRootHelper.app` in the same directory.

## Usage

1. Double-click `ClaudeRootHelper.app` (or `open ClaudeRootHelper.app` from terminal)
2. Enter your admin password when prompted
3. The app window shows a green status dot and a live log of commands
4. (Optional) Expand **"Command Filters"** at the bottom to configure allow/block rules

Run commands as root:

```bash
claude-root-cmd whoami
# root

claude-root-cmd --cwd /etc cat hosts

claude-root-cmd --timeout 30 some-long-running-command
```

5. Quit the app when done — the root server stops automatically

## Claude Code integration

Add this to your global Claude settings (`~/.claude/CLAUDE.md`) so Claude automatically uses the helper when it's running and falls back to `sudo` when it's not:

```markdown
**Root helper app** at /path/to/ClaudeRootHelper.app. When it's running, use
`claude-root-cmd <command>` instead of `sudo`. Supports `--cwd DIR` and
`--timeout SECS`. If `claude-root-cmd` is not available or the helper isn't
running, fall back to `sudo` as normal.
```

## Requirements

- macOS 13.0+
- Xcode command-line tools (for building)

## License

MIT
