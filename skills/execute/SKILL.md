---
name: execute
description: >-
  Single-ticket executor. One ticket per session, end to end. Reads the issue's
  Agent Brief, decomposes it into AFK vs HITL sub-tasks, branches into a
  worktree, dispatches a runner pane and a model-diverse reviewer pane (both live
  tmux TUIs), loops up to 3 times on NO_GO, then ships the AFK part (commit +
  push + PR) and defers the HITL part. Triggers: `/execute`,
  `/execute <repo>#<num>`, `/execute --adversarial-review`, `/execute resume`,
  `/execute stop`.
---

# /execute — single-ticket coordinator

`/execute` is the execution layer of the funnel (`/scope` → **`/execute`** →
`/conduct`). It owns one ticket from a labelled issue to a merged (or
human-deferred) PR. It does NOT plan or classify the work — that's `/scope`'s
brief. It does NOT drive the queue — that's `/conduct`.

## Mental model

```
You (lead)
  │  one /execute session = one ticket, end to end
  ├─ Pick ticket  → a `ready-for-agent` issue (named, or top of the survey)
  ├─ Decompose    → {afk_tasks:[], hitl_tasks:[]} from the brief's criteria
  ├─ Branch       → feature branch in an isolated worktree
  ├─ Runner pane  → live agent TUI, full tools: implement → verify → result JSON
  ├─ Reviewer pane→ live agent TUI, READ-ONLY, DIFFERENT model family → verdict
  ├─ NO_GO        → re-dispatch runner with findings (max 3 attempts)
  ├─ Ship         → lead commits + pushes + opens the PR
  ├─ Classify     → AFK auto-merge, or HITL → notify + defer
  └─ Hand off     → write a note, spawn a fresh /execute for the next ticket
```

Both worker panes are spawned through [`../spawn/SKILL.md`](../spawn/SKILL.md)
(`spawn-mac.sh`), so they are real attachable TUIs, not headless one-shots.

## Engines — diversity is mandatory

The reviewer must be a **different model family** than the runner. A model
reviewing its own output shares its own blind spots; cross-family review is what
makes the gate real.

| Lead engine | Default runner | Default reviewer |
|---|---|---|
| Claude | Codex | Claude (Opus) |
| Codex | Claude (Sonnet) | Codex |

Override per session with `--runner <engine> --reviewer <engine>`
(`opus|sonnet|codex`). Overrides do not persist when the session rotates to the
next ticket. **Never use the cheapest tier for runner/reviewer** — it's fine for
read-only survey sub-agents, not for writing or judging code.

## Reviewer mode

Default review is rigorous but proportionate. Add `--adversarial-review` when a
ticket warrants it: same read-only pane, same JSON verdict, but the reviewer is
explicitly prompted to **prove the change should not ship**. It relies on three
things together — a model-diverse reviewer, a real tmux pane (not a same-model
sub-agent), and a skeptical role prompt. See
[`../../templates/reviewer-prompt.md`](../../templates/reviewer-prompt.md).

Escalate to adversarial automatically for broad/risky work: large diff, critical
paths, sensitive data, migrations, parser/auth/security changes, cross-repo
coupling, or a risk-level-3 surface.

## Lifecycle (per ticket)

```
1. PICK     — a `ready-for-agent` issue (named, or rank the survey and take #1).
              `ready-for-human` issues are filtered out — they need human-only
              judgment / access / design.
2. DECOMPOSE— read the brief's acceptance criteria. Each criterion already
              carries an [AFK]/[HITL] prefix from /scope — USE IT DIRECTLY. Only
              legacy briefs without a prefix fall back to the rubric in
              docs/concepts.md. Preserve `Out of scope` (it belongs to neither
              list). If 100% HITL → defer + hand off, don't dispatch a runner.
3. BRANCH   — create a feature branch in an isolated worktree.
4. RUNNER   — spawn a runner pane with the runner prompt (template) + the brief +
              the AFK task list. Block-wait for its result JSON + sentinel.
5. REVIEWER — spawn a model-diverse reviewer pane, READ-ONLY. Block-wait for its
              verdict: PASS / SOFT / NO_GO / UNAVAILABLE. Mandatory before any
              commit — even if the lead implemented inline.
6. LOOP     — NO_GO → re-dispatch the runner with the findings. Max 3 attempts.
              Still failing at 3 → STOP and hand it to a human; that usually
              means the brief has something you didn't think through.
7. SHIP     — the LEAD commits, pushes, and opens the PR (workers never do git).
8. CLASSIFY — AFK PR → auto-merge; HITL PR → notify + defer to the human queue.
              Mixed ticket → ship the AFK PR, comment the HITL remainder on the
              issue.
9. HAND OFF — write a durable note, then spawn a fresh /execute for the next
              ticket (clean context). One ticket per session.
```

## Reading worker results — durably

- Read a worker's result from the **file it wrote / its captured output**, not
  from a flaky live `capture-pane` scrape. `capture-pane` is for human eyes; the
  result JSON + sentinel is the canonical signal.
- Wait on a **durable artifact** (the result file, the PR state, the issue
  labels), not on transient pane scrollback.

## Optional durability layers (not required to run)

A production setup often adds, on top of the core lifecycle: a cross-pane shared
note (a pinned issue comment) for state durable across machines; an append-only
event log + base-state file for mechanical resume; a proof bundle gate (evidence
before merge) for high-risk tickets. These are **additive** — the four-step
runner/reviewer/ship/handoff loop works without them. Add them only if you need
cross-session resume or an audit trail.

## Anti-patterns

- Spawning two runners concurrently in one session (worktree + rate-limit
  collisions).
- Skipping the reviewer because the lead implemented inline — the runner pane may
  be bypassed for a trivial edit, the reviewer pane may NOT.
- Using a same-model reviewer — defeats the diversity that makes review real.
- Reading a result from `capture-pane` instead of the canonical result file.
- Auto-merging a risk-level-3 / sensitive PR — HITL classification always wins
  there.
- Re-classifying the ticket inside `/execute` — the brief's [AFK]/[HITL] verdict
  is authoritative; consume it.

## Triggers

| Input | Behavior |
|---|---|
| `/execute` | Survey `ready-for-agent` issues, pick top, ship one, hand off. |
| `/execute <repo>#<num>` | Force-pick that ticket (skips selection only; reviewer still mandatory). |
| `/execute --adversarial-review` | Enable adversarial review for this session. |
| `/execute resume` | Read the latest handoff note and continue. |
| `/execute stop` | Write a final handoff + notify; do not spawn the next. |

## See also

- [`../scope/SKILL.md`](../scope/SKILL.md) — produces the brief this consumes
- [`../conduct/SKILL.md`](../conduct/SKILL.md) — drives many `/execute` runs in order
- [`../spawn/SKILL.md`](../spawn/SKILL.md) — the tmux spawn primitive for the panes
- [`../../templates/runner-prompt.md`](../../templates/runner-prompt.md), [`../../templates/reviewer-prompt.md`](../../templates/reviewer-prompt.md)
- [`../../docs/concepts.md`](../../docs/concepts.md) — AFK/HITL rubric, 3-strike rationale, context isolation
