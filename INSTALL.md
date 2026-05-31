# INSTALL — for the AI agent setting this up

> **給人類 / For the human:** 你不用自己讀這份。把這句貼給你的 AI agent，它會照做：
> *"請依照 INSTALL.md 的步驟，幫我安裝並設定 LY-workflow。"*
> (Or: *"Install and configure LY-workflow by following the steps in INSTALL.md."*)
> 底下整份是寫給那個 agent 看的。

You are an AI coding agent (Claude Code, Codex, or similar). A human handed you
this repository (or this file's URL) and asked you to install the LY-workflow for
them. Work through the steps **in order**. Each step has a **check** — do not
proceed past a failed check; report it to the human and stop. Do not skip the
smoke test (step 4); a silent install that never launched a pane is not an
install.

Do not invent paths. Where a value depends on the host, the step says how to
derive it. Treat every command as something you run and then verify, not assume.

---

## 0. Confirm prerequisites

```bash
tmux -V          # need >= 3.3
git --version
command -v gh    # GitHub CLI — used by the issue-tracker contract flow
# at least one agent CLI:
command -v claude
command -v codex
```

**Check:** `tmux` is ≥ 3.3 and at least one of `claude` / `codex` is on `PATH`.
If `tmux` is missing or too old, stop and tell the human to install it
(`brew install tmux` on macOS). `gh` is only needed for the full `/scope` →
`/execute` → `/conduct` contract flow; `/spawn` alone works without it.

If the host is Windows, do NOT use the macOS script directly — read
[`docs/spawning-agents.md`](docs/spawning-agents.md) §"Windows / WSL" and adapt
the pattern (the script here targets macOS/Linux + WSL's native tmux).

---

## 1. Find the agent's skills directory

Skills live in a per-agent directory that the CLI scans on startup. This is a
documented convention of each tool, not a host-specific layout:

- **Claude Code** → `~/.claude/skills/`
- **Codex** → `~/.codex/skills/`

Pick the one matching the CLI you're installing for. Create it if missing:

```bash
SKILLS_DIR="$HOME/.claude/skills"   # or "$HOME/.codex/skills" for Codex
mkdir -p "$SKILLS_DIR"
```

**Check:** `echo "$SKILLS_DIR"` prints an absolute path that exists.

---

## 2. Get the files, then copy the four skills in

You may have been handed this repo locally, OR just this file's URL. Make sure
the files are on disk before copying:

```bash
# If you are already inside a clone of this repo, this finds its root:
REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
# Otherwise, clone it:
if [ -z "$REPO" ] || [ ! -f "$REPO/skills/spawn/spawn-mac.sh" ]; then
  REPO="$HOME/.cache/LY-workflow"
  git clone https://github.com/liyoungc/LY-workflow.git "$REPO" 2>/dev/null \
    || git -C "$REPO" pull --ff-only
fi
test -f "$REPO/skills/spawn/spawn-mac.sh" && echo "REPO=$REPO"
```

**Check:** `REPO=...` printed and points at a directory containing `skills/`.
If the clone failed, the repo may be private or not pushed yet — stop and tell
the human.

Then copy the four skills in:

```bash
cp -R "$REPO"/skills/scope   "$SKILLS_DIR"/
cp -R "$REPO"/skills/execute "$SKILLS_DIR"/
cp -R "$REPO"/skills/conduct "$SKILLS_DIR"/
cp -R "$REPO"/skills/spawn   "$SKILLS_DIR"/
```

**Check:** all four `SKILL.md` files are present:

```bash
ls "$SKILLS_DIR"/{scope,execute,conduct,spawn}/SKILL.md
```

---

## 3. Make the spawn scripts executable

```bash
chmod +x "$SKILLS_DIR"/spawn/spawn-mac.sh
chmod +x "$SKILLS_DIR"/spawn/lib/prompt-babysit.sh
```

**Check:** `test -x "$SKILLS_DIR"/spawn/spawn-mac.sh && echo OK` prints `OK`.

Syntax-check both scripts before trusting them:

```bash
bash -n "$SKILLS_DIR"/spawn/spawn-mac.sh && bash -n "$SKILLS_DIR"/spawn/lib/prompt-babysit.sh && echo "syntax OK"
```

---

## 4. Smoke-test the spawn primitive

`/spawn` is the foundation — `/execute` and `/conduct` are useless if it can't
launch a pane. Test it in two stages.

**4a. Dry run (no tmux needed):**
```bash
"$SKILLS_DIR"/spawn/spawn-mac.sh --dry-run --title smoke 'echo hello'
```
**Check:** it prints a `tmux new-window ...` command and exits 0.

**4b. Real spawn (needs a tmux session):**
```bash
tmux new-session -d -s smoke-test          # create a target session
"$SKILLS_DIR"/spawn/spawn-mac.sh --target smoke-test --title hello 'echo hi from a spawned pane'
```
**Check:** the command prints metadata including `SESSION=smoke-test`,
`WINDOW=hello`, and an `ATTACH=...` line. Attach and confirm the pane ran:
```bash
tmux attach -t smoke-test          # you should see "hi from a spawned pane"; detach with Ctrl-b d
tmux kill-session -t smoke-test    # clean up
```

If you have `claude` and want a full check, spawn it instead of `echo`:
```bash
"$SKILLS_DIR"/spawn/spawn-mac.sh --target smoke-test --title claude-smoke 'reply with the single word OK'
```
and confirm `PROMPT_CONFIRMED=yes` (or attach and see the live TUI). A
`PROMPT_CONFIRMED=warning` means "attach and look" — often a first-launch trust
dialog the human must dismiss once.

---

## 5. (Optional) Configure your risk levels

The workflow tags work by repo **risk level** (1 = docs/config, 2 = tooling,
3 = sensitive/critical) and per-criterion `[AFK]`/`[HITL]`. There is no config
file to edit — these are conventions the skills apply. If you maintain a list of
which repos / paths are sensitive (force HITL review), keep it wherever your
agent reads project context, and tell `/scope` and `/execute` to honor it. See
the rubric in [`docs/concepts.md`](docs/concepts.md).

---

## 6. Verify the skills load

Restart the agent CLI (or start a new session) so it rescans the skills
directory, then confirm the four slash-commands are recognized:

- Claude Code: the skills appear when you type `/` ; or check the session's
  available-skills list.
- Codex: a new `codex` process rescans its skills directory on launch.

**Check:** `/scope`, `/execute`, `/conduct`, `/spawn` are all listed.

---

## How the four commands relate (so you use them correctly)

```
/conduct <problem>
   ├─ spawns /scope <problem>      → files N Agent-Brief contracts on the tracker
   └─ for each contract, in order:
        spawns /execute <ref>      → runner pane + reviewer pane → PR
             └─ both panes are launched via /spawn (tmux live TUI)
```

- Use **`/spawn`** alone to open a side agent for any task.
- Use **`/scope`** to turn a fuzzy request into verifiable contracts (no code).
- Use **`/execute`** to take ONE contract to a shipped PR.
- Use **`/conduct`** to do the whole thing hands-off across many contracts.

Read [`docs/concepts.md`](docs/concepts.md) for the reasoning and
[`docs/spawning-agents.md`](docs/spawning-agents.md) for the tmux details before
running `/execute` or `/conduct` for real.

---

## Install summary (the whole thing, if all checks passed)

```bash
SKILLS_DIR="$HOME/.claude/skills"          # or $HOME/.codex/skills
REPO="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -f "$REPO/skills/spawn/spawn-mac.sh" ] || { REPO="$HOME/.cache/LY-workflow"; git clone https://github.com/liyoungc/LY-workflow.git "$REPO"; }
mkdir -p "$SKILLS_DIR"
cp -R "$REPO"/skills/{scope,execute,conduct,spawn} "$SKILLS_DIR"/
chmod +x "$SKILLS_DIR"/spawn/spawn-mac.sh "$SKILLS_DIR"/spawn/lib/prompt-babysit.sh
bash -n "$SKILLS_DIR"/spawn/spawn-mac.sh && echo "installed; restart the CLI to load the skills"
```
