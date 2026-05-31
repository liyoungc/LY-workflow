#!/usr/bin/env bash
# prompt-babysit.sh — shared prompt-confirmation logic for the spawn scripts.
# Source this file; do not execute it directly.
#
# The problem it solves: after you launch an agent TUI in a tmux pane and send
# it a prompt, you do NOT actually know the prompt is running. Two things can
# silently swallow it:
#   1. A workspace-trust / permission dialog the agent shows on first launch in
#      a new directory. While that modal is up, keystrokes go to the dialog, and
#      a prompt passed as an argv positional is dropped once the modal dismisses.
#   2. The TUI is still booting and the input box isn't ready yet.
# This babysit watches the pane and only reports success once it sees the prompt
# actually being processed (or re-injects it after the trust dialog clears).
#
# Callers may override these thin tmux wrappers (defaults use plain `tmux`):
#   _spawn_babysit_pane_dead PANE_ID      → echo pane_dead value (0/1)
#   _spawn_babysit_capture   PANE_ID      → echo capture-pane scrollback text
#   _spawn_babysit_capture_screen PANE_ID → echo the VISIBLE pane text only
#   _spawn_babysit_send_keys PANE_ID KEYS → send-keys + C-m to the pane
#   _spawn_babysit_paste_file PANE_ID FILE→ paste a file WITHOUT submitting
#   _spawn_babysit_sleep SECONDS          → sleep (tests stub this out)
#
# Tunables (env vars, all optional):
#   SPAWN_BABYSIT_TIMEOUT   total babysit seconds (default 30, set 0 to skip)
#   SPAWN_BABYSIT_POLL      poll interval in seconds (default 1)

# ---------------------------------------------------------------------------
# Overridable helpers — platform wrappers redefine these after sourcing.
# ---------------------------------------------------------------------------

if ! declare -f _spawn_babysit_pane_dead >/dev/null 2>&1; then
  _spawn_babysit_pane_dead() { tmux display-message -t "$1" -p '#{pane_dead}' 2>/dev/null || echo "1"; }
fi
if ! declare -f _spawn_babysit_capture >/dev/null 2>&1; then
  _spawn_babysit_capture() { tmux capture-pane -J -t "$1" -p -S -80 2>/dev/null; }
fi
if ! declare -f _spawn_babysit_capture_screen >/dev/null 2>&1; then
  _spawn_babysit_capture_screen() { tmux capture-pane -J -t "$1" -p 2>/dev/null; }
fi
if ! declare -f _spawn_babysit_send_keys >/dev/null 2>&1; then
  # $1 = pane_id, $2 = keys string — sends text then C-m.
  # IMPORTANT: submit with `C-m`, NOT the named key `Enter`. Ink-based TUIs
  # (Claude Code, many Node TUIs) do not treat the named `Enter` as a submit.
  _spawn_babysit_send_keys() { tmux send-keys -t "$1" "$2" C-m 2>/dev/null || true; }
fi
if ! declare -f _spawn_babysit_sleep >/dev/null 2>&1; then
  _spawn_babysit_sleep() { sleep "$1"; }
fi
# Paste a (tmux-accessible) file into the pane WITHOUT submitting. Used to
# deliver a multi-line prompt robustly (send-keys of a multi-line string would
# submit at the first newline).
if ! declare -f _spawn_babysit_paste_file >/dev/null 2>&1; then
  _spawn_babysit_paste_file() {
    tmux load-buffer -b _spawnpb "$2" 2>/dev/null \
      && tmux paste-buffer -b _spawnpb -t "$1" 2>/dev/null \
      && tmux delete-buffer -b _spawnpb 2>/dev/null || true
  }
fi

# ---------------------------------------------------------------------------
# _spawn_inject_effort PANE_ID EFFORT [READY_TIMEOUT]
#
# For a session launched WITHOUT a seed prompt (bare TUI at the input box):
# wait until the input box is ready (pane alive, trust dialog cleared, TUI
# drawn), type "/effort EFFORT" + Enter, then verify it registered (retry once).
# `/effort` is a Claude Code TUI slash-command — there is no CLI flag for it, so
# injecting it via tmux is the only way to start a spawned session at a given
# reasoning effort. Best-effort: never blocks the spawn.
#
# Tunables: SPAWN_EFFORT_READY_TIMEOUT (default 180s — first launch in a new dir
#           can be slow), SPAWN_EFFORT_STABILIZE (default 4s settle after trust
#           clears), SPAWN_EFFORT_CONFIRM_TIMEOUT (default 8s to see the echo).
# ---------------------------------------------------------------------------
_spawn_inject_effort() {
  local pane_id="$1" effort="$2"
  local ready_timeout="${3:-${SPAWN_EFFORT_READY_TIMEOUT:-180}}"
  local poll="${SPAWN_BABYSIT_POLL:-1}"
  local stabilize="${SPAWN_EFFORT_STABILIZE:-4}"
  local confirm_timeout="${SPAWN_EFFORT_CONFIRM_TIMEOUT:-8}"
  local start now elapsed dead cap screen trust_state

  # 1) Wait for the TUI to be input-ready. If a workspace-trust dialog appears,
  # accept it once, then wait for the post-trust TUI to finish loading. Trust
  # detection uses the VISIBLE screen only; scrollback can retain stale text.
  start=$(date +%s)
  trust_state="none"   # none | accepted | cleared
  while true; do
    now=$(date +%s); elapsed=$(( now - start ))
    if [ "$elapsed" -ge "$ready_timeout" ]; then
      echo "[spawn] WARNING: input box not confirmed ready after ${ready_timeout}s; sending /effort anyway" >&2
      break
    fi
    dead=$(_spawn_babysit_pane_dead "$pane_id")
    if [ "$dead" = "1" ]; then
      echo "[spawn] WARNING: pane $pane_id exited before /effort could be set" >&2
      return 1
    fi
    cap=$(_spawn_babysit_capture "$pane_id")
    screen=$(_spawn_babysit_capture_screen "$pane_id")

    if printf '%s\n' "$screen" | grep -Eiq \
        'Do you trust|trust this (folder|workspace)|workspace trust|Press Enter to continue|enter to continue'; then
      if [ "$trust_state" = "none" ]; then
        echo "[spawn] trust dialog detected in pane $pane_id — pressing Return, then waiting for the TUI to finish loading" >&2
        _spawn_babysit_send_keys "$pane_id" ""
        trust_state="accepted"
        start=$(date +%s)
      fi
      _spawn_babysit_sleep "$poll"; continue
    fi

    if [ "$trust_state" = "accepted" ]; then
      echo "[spawn] trust dialog cleared — waiting for the complete TUI before /effort $effort" >&2
      trust_state="cleared"
      start=$(date +%s)
      _spawn_babysit_sleep "$poll"
      continue
    fi

    # Input-ready heuristic: require visible input/shortcut/status markers from
    # the completed TUI, not just an early welcome/loading line.
    if printf '%s\n' "$screen" | grep -Eq '│ >|>_|for shortcuts|\? for shortcuts|bypass|esc to|tokens'; then
      break
    fi
    _spawn_babysit_sleep "$poll"
  done
  _spawn_babysit_sleep "$stabilize"

  # 2) Type /effort EFFORT, verify it registered, retry once if not.
  local attempt
  for attempt in 1 2; do
    _spawn_babysit_send_keys "$pane_id" "/effort $effort"
    local cstart cnow
    cstart=$(date +%s)
    while true; do
      cnow=$(date +%s)
      [ $(( cnow - cstart )) -ge "$confirm_timeout" ] && break
      cap=$(_spawn_babysit_capture "$pane_id")
      if printf '%s\n' "$cap" | grep -Eiq "effort|${effort}|xhigh"; then
        return 0
      fi
      _spawn_babysit_sleep "$poll"
    done
    echo "[spawn] /effort $effort not confirmed on attempt ${attempt}; retrying" >&2
  done
  echo "[spawn] WARNING: could not confirm /effort $effort registered; continuing (set it manually if needed)" >&2
  return 0
}

# ---------------------------------------------------------------------------
# _spawn_babysit_prompt PANE_ID PROMPT [TIMEOUT]
#
# Polls the tmux pane until one of three outcomes:
#   (a) Running signals detected (Working/Thinking/spinner/etc.) → return 0
#   (b) Trust dialog visible → warn the operator; wait for it to clear; re-inject
#       the original PROMPT via send-keys + C-m; re-check for running signals.
#   (c) TIMEOUT reached with no running signal → print WARNING, return 1.
#
# The caller emits PROMPT_CONFIRMED=yes on rc=0, =warning on rc=1.
# ---------------------------------------------------------------------------
_spawn_babysit_prompt() {
  local pane_id="$1" prompt="$2"
  local timeout="${3:-${SPAWN_BABYSIT_TIMEOUT:-30}}"
  local poll="${SPAWN_BABYSIT_POLL:-1}"

  # Skip entirely when timeout == 0 (backward-compat for callers that pre-date babysit).
  [ "$timeout" -eq 0 ] 2>/dev/null && return 0

  local start trust_state dead cap screen
  start=$(date +%s)
  trust_state="none"   # none | visible | cleared

  while true; do
    local now elapsed
    now=$(date +%s); elapsed=$(( now - start ))
    if [ "$elapsed" -ge "$timeout" ]; then
      printf '[spawn] WARNING: prompt may not be running — no activity after %ds in pane %s\n' \
        "$timeout" "$pane_id" >&2
      return 1
    fi

    dead=$(_spawn_babysit_pane_dead "$pane_id")
    if [ "$dead" = "1" ]; then
      echo "[spawn] WARNING: pane $pane_id exited before the prompt was confirmed running" >&2
      return 1
    fi

    cap=$(_spawn_babysit_capture "$pane_id")
    screen=$(_spawn_babysit_capture_screen "$pane_id")

    # (b) Trust / permission dialog — checked FIRST so it takes precedence over
    # any positive signal. A visible modal blocks input, so the prompt is NOT
    # running even if its text is echoed on screen.
    if [ "$trust_state" != "cleared" ] && printf '%s\n' "$screen" | grep -Eiq \
        'Do you trust|trust this (folder|workspace)|workspace trust|Press Enter to continue|enter to continue'; then
      if [ "$trust_state" = "none" ]; then
        echo "[spawn] WARNING: trust/permission dialog detected in pane $pane_id" >&2
        echo "[spawn]   Action required: dismiss the dialog in the tmux pane above." >&2
        echo "[spawn]   Will re-inject the original prompt once the dialog clears." >&2
        trust_state="visible"
      fi
      _spawn_babysit_sleep "$poll"
      continue
    fi

    # Trust dialog was visible but is now gone — re-inject prompt once.
    if [ "$trust_state" = "visible" ]; then
      echo "[spawn] trust dialog cleared — re-injecting the original prompt via send-keys C-m" >&2
      _spawn_babysit_send_keys "$pane_id" "$prompt"
      trust_state="cleared"
      _spawn_babysit_sleep "$poll"
      continue
    fi

    # (a) Running / activity signals — prompt accepted and processing.
    if printf '%s\n' "$cap" | grep -Eiq \
        'Working|Thinking|esc to interrupt|Running|tokens|⠋|✻|✶|●|⏺|Analyzing|processing'; then
      return 0
    fi

    # (a2) Prompt echo — the original prompt text is visible in the pane,
    # confirming it was submitted. Trusted ONLY after the trust-dialog check.
    if [ -n "$prompt" ] && printf '%s\n' "$cap" | grep -qF "$prompt"; then
      return 0
    fi

    _spawn_babysit_sleep "$poll"
  done
}
