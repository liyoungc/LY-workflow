---
name: spawn
description: >-
  Open a new Claude Code or Codex agent in a tmux pane/window so it runs a live
  TUI (never `claude -p` / `codex exec`), and the lead session can attach to
  watch or intervene. macOS/Linux uses the bundled `spawn-mac.sh` (printf %q
  handles all quoting). Windows/WSL follows the documented file-based-prompt
  pattern in docs/spawning-agents.md. Triggers include `/spawn PROMPT`,
  `/spawn --codex PROMPT`, `/spawn --cwd DIR PROMPT`, "open a new tab for X",
  "spawn a session to ...".
---

# /spawn — open a new agent in tmux

`/spawn` is the lowest layer of the workflow. `/conduct`, `/execute`, and the
rotation step of a long session all call it to launch a fresh agent process in
its own tmux pane. The point is **context isolation**: each ticket gets a clean
agent, and you (the lead) attach to a pane only when you want to watch.

## Why tmux, and why a live TUI

- **Context isolation** — a fresh process per ticket means each agent works at
  its sharpest, not buried under the previous ticket's scrollback.
- **Inter-agent visibility** — panes in one session can see and `send-keys` to
  each other, so a lead can hand a prompt to a runner, and a runner can poke a
  reviewer.
- **Attach to watch** — `tmux attach -t <session>` puts a live view on any pane
  without disturbing it.
- **Live TUI, not headless** — launch the real interactive binary, not
  `claude -p` / `codex exec`. The spawned agent must load its full skill set and
  hooks; the headless one-shot modes skip that.

## Platform matrix

| Platform | Mechanism | Quoting |
|---|---|---|
| **macOS / Linux** | `spawn-mac.sh` → tmux window or split pane | None — `printf %q` escapes any byte |
| **macOS Codex** | `spawn-mac.sh --codex` → `codex -C <cwd> <prompt>` in tmux | None — same `printf %q` |
| **Windows / WSL** | file-based-prompt pattern (see [`../../docs/spawning-agents.md`](../../docs/spawning-agents.md)) | `;` `'` `"` `` ` `` `$` forbidden in the window title; prompt delivered via a file to dodge quoting hazards |

Detect the platform once, up front; never mix branches:

```bash
case "$(uname -s)" in
  Darwin|Linux)         impl=mac ;;   # → spawn-mac.sh
  MINGW*|MSYS*|CYGWIN*) impl=win ;;   # → docs/spawning-agents.md WSL pattern
  *)                    impl=mac ;;
esac
```

## Trigger forms

```
/spawn 'echo hello from a spawned pane'           # smoke test
/spawn '/execute my-app#12'                       # launch an executor on a ticket
/spawn --cwd ~/code/my-app '/execute owner/repo#7'
/spawn --codex --cwd ~/code/my-app '/execute my-app#12'
/spawn --model sonnet 'cost-conscious worker on a well-scoped task'
/spawn --layout split-bottom-half '/execute my-app#12'   # runner pane below lead
/spawn --layout split-bottom-right 'reviewer pane'       # reviewer beside runner
/spawn                                            # blank tab in the lead's cwd
```

## Args (macOS/Linux `spawn-mac.sh`)

| Arg | Effect | Default |
|---|---|---|
| `<prompt>` (positional) | Initial message for the new session. | empty (opens a bare REPL) |
| `--cwd <dir>` | Working directory for the new agent. | invoking session's cwd |
| `--title <name>` | tmux pane/window title. | `claude-HHMM` / `codex-HHMM` |
| `--model <alias>` | Claude model (`opus`/`sonnet`/`haiku` or a full id). Claude branch only. | inherit CLI default |
| `--codex` | Spawn Codex instead of Claude. | off |
| `--codex-model <name>` / `--codex-effort <lvl>` | Codex model / reasoning effort. Require `--codex`. | unset |
| `--layout <mode>` | `new-window` \| `split-bottom-half` \| `split-bottom-right` \| `sidecar-left` \| `sidecar-right` | `new-window` |
| `--target <session>` | Target tmux session. | current `$TMUX` session, else most-recent, else `spawn` |
| `--socket <path>` | Use a dedicated tmux server (`tmux -S`) instead of the user's default. | default server |
| `--tmux-bg` | Open the window without stealing focus. | off (focus steals) |
| `--dry-run` | Print the tmux command and exit. | off |

## Model selection (`--model`)

| Alias | When |
|---|---|
| `opus` | Lead / judgment-heavy / multi-step refactor / architecture. |
| `sonnet` | Sub-agent dispatch, mechanical execution, cost-conscious workers. |
| `haiku` | Cheapest tier — narrow, fast tasks (classifiers, pollers, single-file reads). |

`--model` is rejected with `--codex` (Codex has its own model surface — use
`--codex-model`).

## Quoting & title constraints

- **macOS/Linux**: no constraints. `spawn-mac.sh` round-trips the prompt through
  `printf %q`, so any character (`;` `'` `"` `$` backtick, newlines, UTF-8) is
  safe.
- **Windows/WSL**: the prompt is delivered through a file (no quoting hazards),
  but the **window title** still must not contain `; ' " \` $` (tmux uses them as
  separators). See [`../../docs/spawning-agents.md`](../../docs/spawning-agents.md).

## Known gotchas

- **Submit with `C-m`, not the named `Enter`.** Ink-based TUIs (Claude Code and
  many Node TUIs) do not treat the named key `Enter` as a submit when you
  `tmux send-keys`. The bundled scripts already use `C-m`.
- **Integer tmux session names + `-t`.** `tmux new-window -t "$S"` where `$S` is
  a pure integer (`1`, `10`) is parsed as a *window index in the current
  session*, not as a session name (`create window failed: index N in use`).
  `spawn-mac.sh` always uses `"${TARGET}:"` (trailing colon) to force
  session-target interpretation. Remember this if you call tmux directly.
- **First-launch trust dialog.** On the agent's first run in a new directory it
  may show a workspace-trust prompt that swallows your prompt. `lib/prompt-babysit.sh`
  detects it, presses Return, waits for the TUI, and re-injects the prompt.

## The babysit (prompt confirmation)

After spawning, `spawn-mac.sh` sources [`lib/prompt-babysit.sh`](lib/prompt-babysit.sh)
and waits for evidence the prompt is actually running before reporting success.
It prints `PROMPT_CONFIRMED=yes` (saw activity), `=warning` (timed out or a
dialog blocked it), or `=n/a` (no prompt given). Treat `warning` as "attach and
check the pane", not as a hard failure.

## Negative space

- `/spawn` does NOT take over the new pane after launch — once tmux returns, the
  new agent is on its own (its own hooks fire, its own model handles the prompt).
- `/spawn` does NOT pass any state besides the initial prompt + cwd. For a richer
  handoff, write a durable note first (your own convention) and pass
  `'<resume command> — read <note>'` as the prompt.

## Files

| File | Role |
|---|---|
| [`spawn-mac.sh`](spawn-mac.sh) | macOS/Linux spawn primitive (executable). |
| [`lib/prompt-babysit.sh`](lib/prompt-babysit.sh) | trust-dialog handling + prompt-running confirmation (sourced). |
| [`../../docs/spawning-agents.md`](../../docs/spawning-agents.md) | tmux know-how + the Windows/WSL pattern. |
