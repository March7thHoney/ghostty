# Session restore (macOS)

Ghostty can bring back the terminals you had open the last time it exited:
the same windows, tabs, and splits, each one reopened in the directory it was
in. Tabs that were running `ssh` or Claude Code are picked back up rather than
dropped at a bare shell.

## Enabling it

Session restore follows `window-save-state`. Any value other than `never`
enables it:

```
window-save-state = always
```

`never` disables it completely and removes the snapshot file.

## What gets restored

| | Restored |
|---|---|
| Windows, tabs, splits | Yes, including split ratios and the focused pane |
| Working directory | Yes, per terminal |
| Tab color, tab title override, non-native fullscreen | Yes |
| `ssh` sessions | Reconnected by re-running the same command |
| Claude Code sessions | Resumed with `claude --continue` |
| Any other running program | No — the terminal reopens as a shell in the saved directory |
| Scrollback | No |

Only `ssh` and Claude Code are re-run. Replaying an arbitrary saved command
line would mean re-running whatever the user happened to be in the middle of,
which is fine for `ssh` and destructive for something like `rm` or `git push`.

Restored commands are typed into the restored shell rather than replacing it,
so the tab is a normal shell session: shell integration still applies, the
working directory keeps being tracked, and the tab survives the program exiting.

## What "the last session" means

A snapshot describes the terminals that were open when it was written. Close
one tab out of three and the next snapshot has two, so that tab does not come
back.

Closing your *last* window is the exception: the snapshot is not replaced with
an empty one. Closing the window and then quitting is a normal way to finish
for the day, and it should not be the thing that loses your session. So the
last non-empty snapshot is kept, and the next launch restores it.

Snapshots are written when the terminal layout changes, when a working
directory changes, every 30 seconds, and once more on quit. The periodic write
is what lets a forced quit or a crash still restore something recent.

To start clean, delete the snapshot file or set `window-save-state = never`.

## How this relates to macOS window restoration

macOS has its own restoration mechanism, and Ghostty still uses it. The problem
is that it only runs when macOS decides to, which in practice means a clean
quit while the system is configured to keep windows — quit after a force kill,
or with that system setting off, and there is nothing to restore.

Ghostty therefore keeps its own snapshot at:

```
~/Library/Application Support/com.mitchellh.ghostty/session-state.json
```

The two don't fight: the snapshot is only consulted when macOS restoration
produced no windows. The file is written with `0600` permissions because it
lists every directory you were working in and every host you were connected to.

## Claude Code

A tab running Claude Code is restored as `claude --continue` in the saved
directory, which resumes the most recent conversation for that directory.

Two Claude Code tabs open in the *same* directory will both resume that
directory's most recent conversation, so one of them won't be the conversation
it was before.

Detection deliberately never looks at a Claude version number. Claude Code
installs itself under `<data dir>/claude/versions/<version>` and puts a stable
`claude` on `PATH`, so the resolved executable's own name changes on every
update. Ghostty matches the invoked name and the `claude/versions` directory
layout instead, both of which survive updates.
`SessionRestoreCommandTests` pins this behaviour.

## SSH, and the remote directory

Reconnecting always works: the saved `ssh` command is re-run as-is.

Returning to the **remote** directory is best effort, because Ghostty can only
know the remote working directory if the remote shell reports it with OSC 7.
Ghostty's `+ssh` helper installs terminfo and forwards environment variables;
it does not install shell integration on the remote host, and most shells don't
emit OSC 7 on their own.

When the remote directory is known, the reconnect becomes:

- POSIX remote: `ssh -t -o RemoteCommand=none <original args> 'cd <dir> && exec "${SHELL:-/bin/sh}" -l'`
- Windows remote: `ssh -t -o RemoteCommand=none <original args> 'powershell -NoExit -Command "Set-Location -LiteralPath '\''<dir>'\''"'`

If the remote directory is unknown, or your `ssh` invocation already carried a
remote command, the original command is re-run unchanged.

`RemoteCommand=none` is required rather than tidy. If your `ssh_config` sets a
`RemoteCommand` for the host, ssh refuses to also accept one on the command
line — it fails with "Cannot execute command-line and remote command" — so
without the override the reconnect would not run at all. The trade-off is that
a configured `RemoteCommand` is replaced by the shell we launch. That matches
the usual case, where the configured command is just a shell to log into
(`RemoteCommand powershell` and the like); a host configured to run something
else on connect will get a plain shell instead when restored.

Note that a remote working directory is tracked completely separately from the
local one. It is never used for the titlebar proxy icon or for inheriting a
working directory into a new tab or split, because the path doesn't exist on
your machine.

### Reporting OSC 7 from a remote shell

These go in the profile on the **remote** host. They are optional; without them
you still get the reconnect, just not the directory.

bash — in `~/.bashrc`:

```bash
PROMPT_COMMAND=${PROMPT_COMMAND:+$PROMPT_COMMAND$'\n'}'printf "\033]7;file://%s%s\033\\" "$HOSTNAME" "$PWD"'
```

zsh — in `~/.zshrc`:

```zsh
_ghostty_osc7() { printf '\033]7;file://%s%s\033\\' "$HOST" "$PWD" }
autoload -Uz add-zsh-hook && add-zsh-hook precmd _ghostty_osc7
```

PowerShell — in the file named by `$PROFILE`:

```powershell
function prompt {
    $p = (Get-Location).Path
    $host.UI.Write("`e]7;file://$env:COMPUTERNAME/$($p -replace '\\','/')`a")
    "PS $p> "
}
```

The hostname must be the remote machine's, not `localhost`: a hostname matching
your local machine is treated as a local path, which is the check that stops a
remote host from claiming to know where you are locally.
