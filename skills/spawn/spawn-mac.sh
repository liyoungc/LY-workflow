#!/usr/bin/env bash
# spawn-mac.sh — open a new Claude Code or Codex agent in a tmux pane/window.
#
# This is the macOS/Linux spawn primitive for the LY-workflow. It launches a
# *live* agent TUI inside tmux (NOT `claude -p` / `codex exec`), so the spawned
# session loads its full skills + hooks and can be attached for monitoring.
#
# Why tmux:
#   - Context isolation: each ticket runs in its own fresh agent process.
#   - Inter-agent visibility: panes in the same session can see and send keys
#     to each other (lead → runner → reviewer).
#   - Attach to watch: `tmux attach -t <session>` puts a live view on any pane.
#   - Shell quoting is fully solved by `printf %q` — no special-char constraints
#     (unlike the Windows/WSL path; see docs/spawning-agents.md).
#
# Usage:
#   spawn-mac.sh [--target SESS] [--cwd DIR] [--title NAME] [--layout MODE]
#                [--codex] [--model ALIAS] [--codex-model NAME] [--codex-effort LVL]
#                [--socket PATH] [--tmux-bg] [--dry-run] [PROMPT]
#
# Examples:
#   spawn-mac.sh 'echo hello from a spawned pane'        # smoke test
#   spawn-mac.sh --cwd ~/code/my-app '/execute my-app#12'
#   spawn-mac.sh --codex --cwd ~/code/my-app '/execute owner/repo#7'
#   spawn-mac.sh --model sonnet 'run a cost-conscious worker'
#   spawn-mac.sh --layout split-bottom-half 'runner pane below the lead'
#   spawn-mac.sh --layout split-bottom-right 'reviewer pane next to runner'
#   spawn-mac.sh --tmux-bg 'fire-and-forget side task (no focus steal)'
#   spawn-mac.sh --dry-run --title demo 'print the tmux command, do not run'
#
# Exit codes: 0 spawn OK; 1 environment error; 2 bad flag/usage.

set -u

# PROMPT_CONFIRMED is emitted in the spawn metadata.
# Values: "n/a" (no prompt given), "yes" (activity confirmed), "warning" (timeout/dialog).
PROMPT_CONFIRMED="n/a"

TARGET=""
CWD="$PWD"
TITLE=""
LAYOUT="new-window" # new-window | split-bottom-half | split-bottom-right | sidecar-left | sidecar-right
DRY_RUN=0
CODEX=0
BACKGROUND=0     # tmux FOCUS axis. 0 = default (steal focus to new window). 1 via --tmux-bg.
MODEL=""         # --model <opus|sonnet|haiku|full-id>. Empty = inherit the CLI's global default.
PROMPT=""
SOCKET=""        # empty = user's default tmux server; non-empty = dedicated server via `tmux -S`.
CODEX_MODEL=""   # codex branch only: passed as `-m <name>`.
CODEX_EFFORT=""  # codex branch only: passed as `-c model_reasoning_effort=<lvl>`.

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)       TARGET="$2"; shift 2 ;;
    --cwd)          CWD="$2"; shift 2 ;;
    --title)        TITLE="$2"; shift 2 ;;
    --layout)       LAYOUT="$2"; shift 2 ;;
    --codex)        CODEX=1; shift ;;
    --tmux-bg|--background|--bg) BACKGROUND=1; shift ;;
    --model)        MODEL="$2"; shift 2 ;;
    --socket)       SOCKET="$2"; shift 2 ;;
    --codex-model)  CODEX_MODEL="$2"; shift 2 ;;
    --codex-effort) CODEX_EFFORT="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    --) shift; PROMPT="${*:-}"; break ;;
    -*) echo "spawn-mac.sh: unknown flag: $1" >&2; exit 2 ;;
    *)  PROMPT="$1"; shift ;;
  esac
done

case "$LAYOUT" in
  new-window|split-bottom-half|split-bottom-right|sidecar-left|sidecar-right) ;;
  *)
    echo "spawn-mac.sh: unknown --layout '$LAYOUT' (want new-window|split-bottom-half|split-bottom-right|sidecar-left|sidecar-right)" >&2
    exit 2
    ;;
esac

# --model is meaningful only for the Claude branch. Codex CLI has its own model
# surface (-m / ~/.codex/config.toml), so reject the combination early.
if [[ "$CODEX" -eq 1 ]] && [[ -n "$MODEL" ]]; then
  echo "spawn-mac.sh: --model is not supported with --codex (use --codex-model)." >&2
  exit 2
fi
if [[ "$CODEX" -ne 1 ]] && [[ -n "$CODEX_MODEL$CODEX_EFFORT" ]]; then
  echo "spawn-mac.sh: --codex-model / --codex-effort require --codex." >&2
  exit 2
fi

# --- tmux wrapper: respects optional --socket -------------------------------
# Empty SOCKET hits the user's existing tmux server. A non-empty path uses a
# dedicated server (`tmux -S <path>`), which keeps spawned agents off the
# user's interactive server if desired.
_t() {
  if [[ -n "$SOCKET" ]]; then
    command tmux -S "$SOCKET" "$@"
  else
    command tmux "$@"
  fi
}

# --- Prompt-confirmation babysit (sourced once; shims use _t for socket awareness) ---
_SPAWN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$_SPAWN_DIR/lib/prompt-babysit.sh" ]]; then
  # shellcheck disable=SC1090
  source "$_SPAWN_DIR/lib/prompt-babysit.sh"
fi
unset _SPAWN_DIR
# Override the babysit's plain-tmux shims with socket-aware versions.
_spawn_babysit_pane_dead()      { _t display-message -t "$1" -p '#{pane_dead}' 2>/dev/null || echo "1"; }
_spawn_babysit_capture()        { _t capture-pane -J -t "$1" -p -S -80 2>/dev/null; }
_spawn_babysit_capture_screen() { _t capture-pane -J -t "$1" -p 2>/dev/null; }
_spawn_babysit_send_keys()      { _t send-keys -t "$1" "$2" C-m 2>/dev/null || true; }

# --- 1. Resolve target tmux session -----------------------------------------
# Preference order:
#   (a) explicit --target
#   (b) $TMUX (caller is inside tmux) — use the current session name
#   (c) most-recently-active session
#   (d) a dedicated 'spawn' session (created on demand for sidecar layouts)
if [[ -z "$TARGET" ]] && [[ -n "${TMUX:-}" ]]; then
  TARGET=$(_t display-message -p '#S' 2>/dev/null)
fi
if [[ -z "$TARGET" ]]; then
  TARGET=$(_t list-sessions -F '#{session_name} #{session_activity}' 2>/dev/null \
    | sort -k2 -n -r | head -1 | awk '{print $1}')
fi
if [[ -z "$TARGET" ]]; then
  TARGET="spawn"
fi

# A dry run only prints the tmux command, so it does not require a live session.
if [[ "$DRY_RUN" -eq 0 ]] && ! _t has-session -t "$TARGET" 2>/dev/null; then
  case "$LAYOUT" in
    sidecar-left|sidecar-right) ;;  # these layouts may create the session
    *)
      echo "spawn-mac.sh: target tmux session '$TARGET' does not exist." >&2
      echo "  Start one first:  tmux new-session -s '$TARGET'" >&2
      exit 1
      ;;
  esac
fi

# --- 2. Layout helpers ------------------------------------------------------

SPAWN_TARGET_REF=""
SPAWN_TARGET_KIND=""
SPAWN_PANE_ID=""

_shell_join() {
  local out="" arg
  for arg in "$@"; do
    out="$out $(printf '%q' "$arg")"
  done
  printf '%s\n' "${out# }"
}

_resolve_lead_pane() {
  local pane="" pane_session=""
  if [[ -n "${TMUX_PANE:-}" ]]; then
    pane_session=$(_t display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null || true)
    [[ "$pane_session" == "$TARGET" ]] && pane="$TMUX_PANE"
  fi
  if [[ -z "$pane" ]]; then
    pane=$(_t display-message -p -t "${TARGET}:" '#{pane_id}' 2>/dev/null || true)
  fi
  if [[ -z "$pane" ]]; then
    echo "spawn-mac.sh: could not resolve a lead pane in tmux session '$TARGET'" >&2
    return 1
  fi
  printf '%s\n' "$pane"
}

_pane_window_id() { _t display-message -p -t "$1" '#{window_id}' 2>/dev/null; }
_window_has_pane() { _t display-message -p -t "$1" '#{window_id}' >/dev/null 2>&1; }

_apply_split_layout() {
  local window_id="$1"
  _t set-window-option -t "$window_id" main-pane-height 50% >/dev/null 2>&1 \
    || _t set-window-option -t "$window_id" main-pane-height 50 >/dev/null 2>&1 || true
  _t select-layout -t "$window_id" main-horizontal >/dev/null 2>&1 || true
}

_pane_exists_in_window() {
  local pane="$1" window_id="$2" pane_window=""
  pane_window=$(_pane_window_id "$pane" 2>/dev/null || true)
  [[ -n "$pane_window" && "$pane_window" == "$window_id" ]]
}

_resolve_bottom_pane() {
  local lead_pane="$1" window_id="$2" stored="" fallback=""
  stored=$(_t show-options -w -v -t "$window_id" @spawn_bottom_pane 2>/dev/null || true)
  if [[ -n "$stored" ]] && _pane_exists_in_window "$stored" "$window_id"; then
    printf '%s\n' "$stored"; return 0
  fi
  fallback=$(_t list-panes -t "$window_id" -F '#{pane_id}	#{pane_top}	#{pane_left}	#{pane_dead}' 2>/dev/null \
    | awk -F '\t' -v lead="$lead_pane" '$1 != lead && $4 != "1" { print $2 "\t" $3 "\t" $1 }' \
    | sort -nr -k1,1 -k2,2n | awk -F '\t' 'NR == 1 { print $3 }')
  if [[ -z "$fallback" ]]; then
    echo "spawn-mac.sh: --layout split-bottom-right needs an existing bottom split pane" >&2
    return 1
  fi
  printf '%s\n' "$fallback"
}

_sidecar_window_id() {
  local sidecar_name="${SPAWN_SIDECAR_WINDOW_NAME:-spawn-panes}" stored="" by_name=""
  stored=$(_t show-options -v -t "$TARGET" @spawn_sidecar_window 2>/dev/null || true)
  if [[ -n "$stored" ]] && _window_has_pane "$stored"; then
    printf '%s\n' "$stored"; return 0
  fi
  by_name=$(_t list-windows -t "$TARGET" -F '#{window_id}	#{window_name}' 2>/dev/null \
    | awk -F '\t' -v name="$sidecar_name" '$2 == name { print $1; exit }')
  [[ -n "$by_name" ]] && { printf '%s\n' "$by_name"; return 0; }
  return 1
}

_resolve_sidecar_left_pane() {
  local window_id="$1" stored="" fallback=""
  stored=$(_t show-options -w -v -t "$window_id" @spawn_sidecar_left_pane 2>/dev/null || true)
  if [[ -n "$stored" ]] && _pane_exists_in_window "$stored" "$window_id"; then
    printf '%s\n' "$stored"; return 0
  fi
  fallback=$(_t list-panes -t "$window_id" -F '#{pane_id}	#{pane_left}	#{pane_dead}' 2>/dev/null \
    | awk -F '\t' '$3 != "1" { print $2 "\t" $1 }' | sort -n -k1,1 | awk -F '\t' 'NR == 1 { print $2 }')
  [[ -n "$fallback" ]] || return 1
  printf '%s\n' "$fallback"
}

_apply_sidecar_layout() { _t select-layout -t "$1" even-horizontal >/dev/null 2>&1 || true; }

_spawn_tmux_shell() {
  local inner_cmd="$1" win_name="$2"
  local lead_pane="" window_id="" bottom_pane="" new_pane=""
  local tmux_flags=()

  case "$LAYOUT" in
    new-window)
      # NOTE the trailing colon on "${TARGET}:" — a pure-integer session name
      # like `1` would otherwise be parsed by tmux as a *window index in the
      # current session*, not as the session. The colon forces session-target
      # interpretation and picks the next free window index.
      tmux_flags=("-P" "-F" '#{pane_id}' "-t" "${TARGET}:" "-n" "$win_name" "-c" "$CWD")
      [[ "$BACKGROUND" -eq 1 ]] && tmux_flags=("-d" "${tmux_flags[@]}")
      if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "DRY RUN — would execute:"
        echo "  tmux new-window $(_shell_join "${tmux_flags[@]}") \\"
        echo "    $(printf '%q' "$inner_cmd")"
        echo
        echo "Attach with: tmux a -t $TARGET"
        exit 0
      fi
      new_pane=$(_t new-window "${tmux_flags[@]}" "$inner_cmd") || return $?
      SPAWN_TARGET_REF="$TARGET:$win_name"; SPAWN_TARGET_KIND="window"; SPAWN_PANE_ID="$new_pane"
      return 0
      ;;

    split-bottom-half)
      lead_pane=$(_resolve_lead_pane) || return $?
      window_id=$(_pane_window_id "$lead_pane") || return $?
      tmux_flags=("-v" "-t" "$lead_pane" "-p" "50" "-c" "$CWD" "-P" "-F" '#{pane_id}')
      [[ "$BACKGROUND" -eq 1 ]] && tmux_flags=("-d" "${tmux_flags[@]}")
      if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "DRY RUN — would execute:"
        echo "  tmux split-window $(_shell_join "${tmux_flags[@]}") $(printf '%q' "$inner_cmd")"
        exit 0
      fi
      new_pane=$(_t split-window "${tmux_flags[@]}" "$inner_cmd") || return $?
      _t select-pane -t "$new_pane" -T "$win_name" >/dev/null 2>&1 || true
      _t set-window-option -t "$window_id" @spawn_bottom_pane "$new_pane" >/dev/null 2>&1 || true
      _apply_split_layout "$window_id"
      SPAWN_TARGET_REF="$new_pane"; SPAWN_TARGET_KIND="pane"; SPAWN_PANE_ID="$new_pane"
      return 0
      ;;

    split-bottom-right)
      lead_pane=$(_resolve_lead_pane) || return $?
      window_id=$(_pane_window_id "$lead_pane") || return $?
      bottom_pane=$(_resolve_bottom_pane "$lead_pane" "$window_id") || return $?
      tmux_flags=("-h" "-t" "$bottom_pane" "-p" "50" "-c" "$CWD" "-P" "-F" '#{pane_id}')
      [[ "$BACKGROUND" -eq 1 ]] && tmux_flags=("-d" "${tmux_flags[@]}")
      if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "DRY RUN — would execute:"
        echo "  tmux split-window $(_shell_join "${tmux_flags[@]}") $(printf '%q' "$inner_cmd")"
        exit 0
      fi
      new_pane=$(_t split-window "${tmux_flags[@]}" "$inner_cmd") || return $?
      _t select-pane -t "$new_pane" -T "$win_name" >/dev/null 2>&1 || true
      _apply_split_layout "$window_id"
      SPAWN_TARGET_REF="$new_pane"; SPAWN_TARGET_KIND="pane"; SPAWN_PANE_ID="$new_pane"
      return 0
      ;;

    sidecar-left)
      local sidecar_name="${SPAWN_SIDECAR_WINDOW_NAME:-spawn-panes}"
      tmux_flags=("-t" "${TARGET}:" "-n" "$sidecar_name" "-c" "$CWD" "-P" "-F" '#{pane_id}')
      [[ "$BACKGROUND" -eq 1 ]] && tmux_flags=("-d" "${tmux_flags[@]}")
      if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "DRY RUN — would create sidecar window '$sidecar_name' in session $TARGET"
        echo "  command: $(printf '%q' "$inner_cmd")"
        exit 0
      fi
      if ! _t has-session -t "$TARGET" 2>/dev/null; then
        _t new-session -d -s "$TARGET" -n "$sidecar_name" -c "$CWD" "$inner_cmd" || return $?
        new_pane=$(_t display-message -p -t "${TARGET}:${sidecar_name}" '#{pane_id}' 2>/dev/null) || return $?
      else
        new_pane=$(_t new-window "${tmux_flags[@]}" "$inner_cmd") || return $?
      fi
      _t select-pane -t "$new_pane" -T "$win_name" >/dev/null 2>&1 || true
      window_id=$(_pane_window_id "$new_pane") || return $?
      _t set-option -t "$TARGET" @spawn_sidecar_window "$window_id" >/dev/null 2>&1 || true
      _t set-window-option -t "$window_id" @spawn_sidecar_left_pane "$new_pane" >/dev/null 2>&1 || true
      _apply_sidecar_layout "$window_id"
      SPAWN_TARGET_REF="$new_pane"; SPAWN_TARGET_KIND="pane"; SPAWN_PANE_ID="$new_pane"
      return 0
      ;;

    sidecar-right)
      window_id=$(_sidecar_window_id) || {
        echo "spawn-mac.sh: --layout sidecar-right needs an existing sidecar-left pane" >&2
        return 1
      }
      bottom_pane=$(_resolve_sidecar_left_pane "$window_id") || {
        echo "spawn-mac.sh: --layout sidecar-right could not resolve the sidecar-left pane" >&2
        return 1
      }
      tmux_flags=("-h" "-t" "$bottom_pane" "-p" "50" "-c" "$CWD" "-P" "-F" '#{pane_id}')
      [[ "$BACKGROUND" -eq 1 ]] && tmux_flags=("-d" "${tmux_flags[@]}")
      if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "DRY RUN — would split sidecar window for the right pane"
        echo "  command: $(printf '%q' "$inner_cmd")"
        exit 0
      fi
      new_pane=$(_t split-window "${tmux_flags[@]}" "$inner_cmd") || return $?
      _t select-pane -t "$new_pane" -T "$win_name" >/dev/null 2>&1 || true
      _t set-window-option -t "$window_id" @spawn_sidecar_right_pane "$new_pane" >/dev/null 2>&1 || true
      _apply_sidecar_layout "$window_id"
      SPAWN_TARGET_REF="$new_pane"; SPAWN_TARGET_KIND="pane"; SPAWN_PANE_ID="$new_pane"
      return 0
      ;;
  esac
}

_emit_spawn_metadata() {
  local attach_cmd=""
  if [[ "$SPAWN_TARGET_KIND" == "pane" && -n "$SPAWN_PANE_ID" ]]; then
    if [[ -n "$SOCKET" ]]; then
      attach_cmd="tmux -S $(printf '%q' "$SOCKET") attach -t $(printf '%q' "$TARGET") \\; select-pane -t $(printf '%q' "$SPAWN_PANE_ID")"
    else
      attach_cmd="tmux attach -t $(printf '%q' "$TARGET") \\; select-pane -t $(printf '%q' "$SPAWN_PANE_ID")"
    fi
  else
    if [[ -n "$SOCKET" ]]; then
      attach_cmd="tmux -S $(printf '%q' "$SOCKET") attach -t $(printf '%q' "${TARGET}:${WIN_NAME}")"
    else
      attach_cmd="tmux attach -t $(printf '%q' "${TARGET}:${WIN_NAME}")"
    fi
  fi
  echo "SESSION=$TARGET"
  echo "WINDOW=$WIN_NAME"
  echo "SOCKET=${SOCKET:-default}"
  echo "LAYOUT=$LAYOUT"
  echo "TARGET_KIND=$SPAWN_TARGET_KIND"
  echo "TARGET_REF=$SPAWN_TARGET_REF"
  [[ -n "$SPAWN_PANE_ID" ]] && echo "PANE_ID=$SPAWN_PANE_ID"
  echo "ATTACH=$attach_cmd"
  echo "PROMPT_CONFIRMED=${PROMPT_CONFIRMED:-n/a}"
}

# --- 3. Codex branch --------------------------------------------------------

if [[ "$CODEX" -eq 1 ]]; then
  CODEX_BIN=$(command -v codex 2>/dev/null)
  if [[ -z "$CODEX_BIN" ]] || [[ ! -x "$CODEX_BIN" ]]; then
    echo "spawn-mac.sh: cannot locate 'codex' in PATH" >&2
    exit 1
  fi
  WIN_NAME="${TITLE:-codex-$(date +%H%M)}"
  # `codex -C <cwd>` sets the working dir; the prompt is the trailing positional.
  INNER_CMD="$(printf '%q' "$CODEX_BIN") -C $(printf '%q' "$CWD")"
  [[ -n "$CODEX_MODEL" ]] && INNER_CMD="$INNER_CMD -m $(printf '%q' "$CODEX_MODEL")"
  # Codex CLI accepts `-c key=value` to override any config.toml field.
  [[ -n "$CODEX_EFFORT" ]] && INNER_CMD="$INNER_CMD -c $(printf '%q' "model_reasoning_effort=$CODEX_EFFORT")"
  [[ -n "$PROMPT" ]] && INNER_CMD="$INNER_CMD $(printf '%q' "$PROMPT")"
  INNER_CMD="$INNER_CMD; echo; echo '[spawn] codex session ended — Ctrl-D to close, or run codex again'; exec \"\$SHELL\" -i"

  _spawn_tmux_shell "$INNER_CMD" "$WIN_NAME"
  RC=$?
  if [[ $RC -eq 0 ]]; then
    if [[ -n "$PROMPT" ]] && [[ -n "$SPAWN_PANE_ID" ]] && declare -f _spawn_babysit_prompt >/dev/null 2>&1; then
      if _spawn_babysit_prompt "$SPAWN_PANE_ID" "$PROMPT"; then PROMPT_CONFIRMED="yes"; else PROMPT_CONFIRMED="warning"; fi
    fi
    _emit_spawn_metadata
    [[ -n "$PROMPT" ]] && echo "        prompt:      $PROMPT"
  else
    echo "spawn-mac.sh: tmux spawn (--codex, layout=$LAYOUT) failed (rc=$RC)" >&2
    exit $RC
  fi
  exit 0
fi

# --- 4. Claude branch -------------------------------------------------------

CLAUDE_BIN=$(command -v claude 2>/dev/null)
[[ -z "$CLAUDE_BIN" ]] && CLAUDE_BIN="${CLAUDE_CODE_EXECPATH:-}"
if [[ -z "$CLAUDE_BIN" ]] || [[ ! -x "$CLAUDE_BIN" ]]; then
  echo "spawn-mac.sh: cannot locate 'claude' (PATH and CLAUDE_CODE_EXECPATH both miss)" >&2
  exit 1
fi

WIN_NAME="${TITLE:-claude-$(date +%H%M)}"
INNER_CMD="$(printf '%q' "$CLAUDE_BIN")"
[[ -n "$MODEL" ]] && INNER_CMD="$INNER_CMD --model $(printf '%q' "$MODEL")"
# printf %q escapes any chars for safe re-eval by the shell — no special-char
# restrictions on the prompt (the Windows/WSL path is the fragile one).
[[ -n "$PROMPT" ]] && INNER_CMD="$INNER_CMD $(printf '%q' "$PROMPT")"
# Keep the pane alive after the agent exits so output is readable / re-runnable.
INNER_CMD="$INNER_CMD; echo; echo '[spawn] session ended — Ctrl-D to close, or run claude again'; exec \"\$SHELL\" -i"

_spawn_tmux_shell "$INNER_CMD" "$WIN_NAME"
RC=$?
if [[ $RC -eq 0 ]]; then
  if [[ -n "$PROMPT" ]] && [[ -n "$SPAWN_PANE_ID" ]] && declare -f _spawn_babysit_prompt >/dev/null 2>&1; then
    if _spawn_babysit_prompt "$SPAWN_PANE_ID" "$PROMPT"; then PROMPT_CONFIRMED="yes"; else PROMPT_CONFIRMED="warning"; fi
  fi
  _emit_spawn_metadata
  if [[ -n "$SOCKET" ]]; then
    echo "        attach with: tmux -S $SOCKET attach -t $TARGET"
  else
    echo "        attach with: tmux a -t $TARGET"
  fi
  [[ -n "$PROMPT" ]] && echo "        prompt:      $PROMPT"
else
  echo "spawn-mac.sh: tmux spawn failed (layout=$LAYOUT, rc=$RC)" >&2
  exit $RC
fi
