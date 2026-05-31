# Spawning agents in tmux — the know-how

This is the part people get wrong the most: actually launching one AI agent from
another, reliably, so it boots, accepts its prompt, and can be watched. The
bundled `skills/spawn/spawn-mac.sh` encodes all of this for macOS/Linux; this doc
explains *why* each piece is there and gives the Windows/WSL pattern (which we
document rather than ship, because it's environment-specific).

## Why tmux, and why a live TUI

- **Context isolation.** Each ticket runs in its own fresh agent process. A
  long-lived agent doing many tickets degrades as its context fills; a new
  process per ticket keeps each one sharp.
- **Agents can see and message each other.** Panes in one tmux session can read
  and `send-keys` to each other. A lead hands a prompt to a runner; a runner can
  poke a reviewer. That cross-talk is sometimes exactly what you want.
- **Attach to watch, detach to leave alone.** `tmux attach -t <session>` is a
  live window onto any pane; detaching leaves it running. You can supervise four
  agents by flipping between panes.
- **Survives.** A tmux session outlives the terminal you launched it from, so a
  batch keeps running after you close the laptop lid / disconnect.
- **Launch the real TUI, not the headless mode.** Use the interactive binary
  (`claude`, `codex`), NOT `claude -p` / `codex exec`. The spawned agent must
  load its full skills and hooks; the one-shot headless modes skip that and you
  get a crippled agent.

## macOS / Linux — the easy case

`spawn-mac.sh` builds a tmux command and runs the agent inside a pane. The one
thing that makes it painless: **all shell quoting is solved by `printf %q`.** The
prompt is round-tripped through `printf %q` before being embedded in the inner
command, so any character — `;` `'` `"` `$`, backticks, newlines, UTF-8 — is
safe. No constraints on prompt content.

Claude:
```bash
# (conceptually, what spawn-mac.sh does)
INNER="$(printf '%q' "$CLAUDE_BIN") $(printf '%q' "$PROMPT")"
tmux new-window -t "${SESSION}:" -n "$TITLE" -c "$CWD" "$INNER"
```

Codex on macOS — it has no `/bg`-style background mode, so just run it as a
normal foreground process in a new window. `codex -C <cwd>` sets the working
directory; the prompt is the trailing positional:
```bash
INNER="$(printf '%q' "$CODEX_BIN") -C $(printf '%q' "$CWD") $(printf '%q' "$PROMPT")"
tmux new-window -t "${SESSION}:" -n "$TITLE" -c "$CWD" "$INNER"
```

## Windows / WSL — the fragile case (pattern, not a shipped script)

On Windows the robust path is **WSL's native tmux** driving the Windows agent
binary through `cmd.exe` interop. Three things bite, in order:

**1. `cmd.exe` interop eats backslashes.** When a bash → `cmd.exe` chain passes a
quoted argument, backslashes inside it are stripped. So any executable path you
hand to `cmd.exe` must use **forward slashes**:
```
cmd.exe /c "C:/path/to/pwsh.exe" -NoProfile -File "C:/path/to/wrapper.ps1"
#            ^ forward slashes, not C:\path\to\pwsh.exe
```

**2. Prompt quoting is a minefield — so don't quote, use a file.** Embedding the
prompt inside a `pwsh -Command` string breaks on two characters specifically:

| Char | Why it breaks | Symptom |
|---|---|---|
| `;` | parsed as a command separator at the terminal layer | the prompt fires as two commands; wrong state, often invisible |
| `'` | terminates the single-quoted inner string early | truncated prompt or a syntax error |

The fix: **write the prompt to a file** and have the wrapper read it raw
(PowerShell `Get-Content -Raw`). The file path carries no prompt content, so
there's nothing to escape. Spaces, quotes, semicolons in the prompt all become
harmless.

**3. The window title still has constraints.** Even with a file-based prompt, the
tmux **window title** must not contain `; ' " \` $` — tmux uses them as
separators. Validate the title before spawning; refuse with a clear message and
suggest `,` or an em-dash instead of `;`, and avoiding contractions (`it's` →
`it is`).

Sketch of the chain:
```
bash (MSYS/git-bash)
  → wsl.exe -d <distro> -- tmux new-window -c /mnt/<drive>/<cwd> \
       cmd.exe /c "C:/.../pwsh.exe" -NoProfile -File "C:/.../<title>-spawn.ps1"
         → pwsh wrapper: set env, Set-Location $cwd,
            $p = Get-Content -Raw "<title>-prompt.txt"
            & claude.exe $p     # or codex
```
Attach from anywhere with:
```
wsl -d <distro> -- tmux attach -t <session>:<title>
```

## The babysit — confirming the prompt actually runs

After you spawn, you do **not** know the prompt is running. Two things silently
swallow it:

1. **The first-launch trust dialog.** On an agent's first run in a new directory
   it may show a workspace-trust / permission prompt. While that modal is up,
   keystrokes go to the dialog — and a prompt passed as an argv positional is
   dropped when the modal dismisses.
2. **The TUI is still booting** and the input box isn't ready.

`skills/spawn/lib/prompt-babysit.sh` handles both: it polls the pane, and

- detects a trust dialog on the **visible screen** (not scrollback, which keeps
  stale text), presses Return once, waits for the full TUI to draw, then
  **re-injects the original prompt**;
- confirms "running" only when it sees activity (a spinner, `Working`,
  `Thinking`, `esc to interrupt`, token counts) or the prompt text echoed back.

It reports `PROMPT_CONFIRMED=yes` / `warning` / `n/a`. Treat `warning` as "attach
and look", not a hard failure.

For a session you launch **bare** (no seed prompt — lands at the input box), the
same library can type a TUI slash-command after the box is ready — e.g.
`_spawn_inject_effort` types `/effort <level>` and verifies it registered. That's
the only way to start a spawned session at a given reasoning effort, since
there's no CLI flag for it.

## Two gotchas that waste an hour each

**Submit with `C-m`, not the named `Enter`.** Ink-based TUIs (Claude Code and
many Node TUIs) ignore the named key `Enter` from `tmux send-keys`. They submit
on `C-m`. If you `send-keys 'something' Enter` and the prompt just sits in the
input box, this is why.

**Integer tmux session names collide with `-t`.** `tmux new-window -t "$S"` where
`$S` is a pure integer (`1`, `10`) is parsed as a *window index in the current
session*, not as the session named `1` — you get `create window failed: index N
in use` even though session N exists. Always use a trailing colon:
`tmux new-window -t "${S}:"` forces session-target interpretation and picks the
next free index. `spawn-mac.sh` does this everywhere.

## Watching a batch

- `tmux attach -t <session>` then `Ctrl-b w` to flip between panes (lead / runner
  / reviewer).
- `tmux capture-pane -t <pane> -p` to read a pane's text non-interactively (for
  human eyes only — for *programmatic* completion detection, read the worker's
  result file + sentinel, not a scrape; scrollback is lossy and racy).
- Lay out a lead + runner + reviewer in one window with the `split-bottom-half`
  then `split-bottom-right` layouts (see `spawn-mac.sh --layout`).
