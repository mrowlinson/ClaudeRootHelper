# Claude Root Helper

A lightweight macOS app that gives Claude Code (or any CLI tool) a way to run commands as root without needing `sudo` in the terminal.

Claude Code restricts direct use of `sudo`. This helper runs a small root-privileged server in the background, authenticated via macOS's native admin password prompt. A companion CLI tool (`claude-root-cmd`) sends commands to the server and returns the result.

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

### Caveats

- This is an **unrestricted root shell** for the authenticated user. Any command sent through the socket is executed as root via `/bin/sh -c`. There is no command allowlist.
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

Run commands as root:

```bash
claude-root-cmd whoami
# root

claude-root-cmd --cwd /etc cat hosts

claude-root-cmd --timeout 30 some-long-running-command
```

4. Quit the app when done — the root server stops automatically

## Claude Code integration

Add this to your `CLAUDE.md` or project instructions:

```
Use `claude-root-cmd <command>` instead of `sudo` when root access is needed.
```

## Requirements

- macOS 13.0+
- Xcode command-line tools (for building)

## License

MIT
