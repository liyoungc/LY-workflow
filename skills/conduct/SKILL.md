---
name: conduct
description: >-
  The conductor. One command takes a raw problem (or an existing ready-for-agent
  queue) to shipped PRs: spawn `/scope` once to produce N issue contracts, then
  iterate — spawn `/execute` per contract in dependency order. Stays thin: holds
  only the contract refs and a one-line result per ref, never working context.
  Triggers: `/conduct <problem>`, `/conduct` (over an existing queue),
  `/conduct stop`.
---

# /conduct — the conductor (scope → execute pipeline)

`/conduct` is the top of the funnel (`/scope` → `/execute` → **`/conduct`**). It
does NOT write code and does NOT classify — it only spawns and iterates. This is
the "指揮者 AI" layer: it reads the raw request, gets it turned into contracts,
then handles the tedious admin of running each contract to a shipped PR, only
pulling you in when a real human decision surfaces.

> **Invariant — conduct holds only artifacts, never working context.** Every
> piece of state it carries forward is re-derivable from the issue tracker
> (`gh issue view` / `gh pr view`). If you catch yourself reading a diff or a
> pane's scrollback in the conduct session, stop — that belongs inside a spawned
> `/execute`. The heavy context (exploration, diffs, runner/reviewer scrollback)
> lives and dies inside the spawned sessions.

## Triggers

| Input | Behavior |
|---|---|
| `/conduct <raw problem>` | Spawn `/scope` to turn the problem into N contracts, then iterate `/execute` over them. |
| `/conduct` (bare, over a queue) | Skip scope; iterate `/execute` over the repo's current `ready-for-agent` issues, dependency-ordered. |
| `/conduct stop` | Write a handoff of the remaining queue and exit; do not spawn. |

## Algorithm

```
1. INTAKE
   - problem mode → spawn /scope (fresh context) with the problem; wait for its
     completion; then read back the N filed contract refs.
   - queue mode   → skip; refs are the repo's current ready-for-agent issues.
2. READ REFS
   - Prefer a refs file the spawned /scope writes (one `owner/repo#N` per line).
   - Fallback: list issues + filter locally, polling until the count matches what
     /scope reported (search indexes lag a few seconds). "fewer than reported" is
     a thing to surface, not to silently accept.
3. BUILD ORDER — for each ref read its brief's `Blocked by: #N`. Topologically
   sort. A ref whose blocker has not merged yet is DEFERRED this pass and
   re-checked after its blocker lands.
4. ITERATE  (strictly sequential — NEVER two /execute at once: worktree, rate
   limit, and claim-label collisions)
     for ref in order where blocker(s) merged:
       spawn /execute <ref>  (fresh context)
       WAIT on a DURABLE artifact, NOT pane scrollback: poll the PR state +
       the issue labels (merged / ready-for-human / claim cleared).
       record {ref, pr_url, disposition}   ← one line only
5. TERMINALS
   (a) scope produced 0 ready-for-agent → surface + stop (do NOT re-scope; that
       is scope's job).
   (b) every contract is HITL / ready-for-human → notify + stop.
   (c) partial → ship the AFK-ready ones, then report the HITL remainder + any
       still-blocked refs.
6. HANDOFF — write a summary {shipped, deferred-HITL, still-blocked} and stop.
   One problem per conduct run; it does not auto-start a fresh conductor.
```

## Spawn topology (conduct is the top; depth ≤ 3)

```
/conduct  (holds only refs + one-line results)
  ├─ spawn /scope    → writes N contracts to the issue tracker → refs file
  └─ for each contract, sequentially:
       spawn /execute <ref>
            └─ /execute spawns its own runner + reviewer panes (its lifecycle)
       conduct reads back only {ref, pr_url, disposition} from the tracker
```

When `/conduct` spawns `/scope` or `/execute`, it tells them they run for
context isolation: do the full procedure, leave the durable artifact (issue
contract / PR + labels), then stop — their output IS the artifact, not a chat
reply. Invoked directly by a human (not by conduct), the same skills run inline
and chat back as usual.

## Merge disposition (do not pre-guess)

`/conduct` does NOT decide AFK vs HITL merge — that is `/execute`'s diff-time
call per ticket. The brief carries only the **risk-level** fact; conduct displays
"risk-3: HITL-gated at merge" rather than guessing a disposition.

## Anti-patterns

- Reading a diff or pane scrollback in the conduct session (violates
  holds-only-artifacts — re-derive from the tracker).
- Spawning two `/execute` concurrently (claim / worktree / rate-limit collisions).
- Re-scoping inside conduct when scope returned nothing (that's scope's job).
- Waiting on pane scrollback for completion instead of a durable artifact (PR
  state, issue labels).

## See also

- [`../scope/SKILL.md`](../scope/SKILL.md) — intake / contract producer (conduct spawns this once)
- [`../execute/SKILL.md`](../execute/SKILL.md) — single-contract executor (conduct spawns this per ref)
- [`../spawn/SKILL.md`](../spawn/SKILL.md) — the tmux spawn primitive underneath
- [`../../docs/concepts.md`](../../docs/concepts.md) — the two-phase model + the conductor's role
