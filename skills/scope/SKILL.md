---
name: scope
description: >-
  Intake. Turn a raw problem or a ticket reference into one or more verifiable
  issue contracts (Agent Briefs) for `/execute`. Classifies the work (mechanical
  clone, feature slice, bug fix, or design-first), runs the matching pre-flight,
  then writes a brief whose every acceptance criterion is verifiable and tagged
  `[AFK]` or `[HITL]`. Does NOT write code. Triggers: `/scope <problem>`,
  `/scope <repo>#<num>`, `/scope <github-url>`, `/scope --dry-run <ref>`.
---

# /scope — turn a problem into verifiable contracts

`/scope` is the planning layer of the funnel: **`/scope` (intake) → `/execute`
(execution) → `/conduct` (conductor)**. It produces or refreshes the durable
**Agent Brief** contract on an issue and hands off. It never branches, edits
code, or ships.

> A one-line request ("make the report auto-summarize trends") is not a project.
> `/scope`'s job is to break it into tickets small enough to finish, verify, and
> merge independently, and to write down — for each one — exactly what "done"
> means and which decisions only a human can make.

## What it produces

For each ticket, a `## Agent Brief` comment following
[`../../templates/agent-brief.md`](../../templates/agent-brief.md), with:

- **Verifiable acceptance criteria** — concrete enough that the runner can check
  its own answer. "Emits valid JSON with one object per row" is verifiable.
  "Add the export feature" is not.
- **`[AFK]` / `[HITL]` prefix per criterion** — classified here, once. `/execute`
  is a pure consumer of this verdict; it does not re-run the rubric. (Rubric in
  [`../../docs/concepts.md`](../../docs/concepts.md).)
- **Risk level** (1/2/3) and **Blocked by** (`#N` / None) facts, so `/conduct`
  can order tickets and the merge gate knows the surface.
- Labels: exactly one state label — `ready-for-agent` (a complete brief) or
  `ready-for-human` / `needs-info` (a judgment call or missing input remains).

## Classify first (first match wins)

Apply top-down. Order matters: explicit overrides → safety → design blockers →
mechanical signals → default.

| # | Signal | Path |
|---|---|---|
| 1 | User explicitly named a path ("mechanical", "feature", "design this") | that path |
| 2 | Touches sensitive/critical data or an audit/safety invariant | **Design-first + HITL flag** |
| 3 | Introduces a new module shape, public API, or architectural decision | **Design-first** |
| 4 | `bug`/`regression` label, or title/body describes "expected vs actual" | **Bug-fix** |
| 5 | A proven pattern exists to clone AND a mechanical oracle (e.g. golden/byte-eq test) is derivable | **Mechanical** |
| 6 | Spans ≥2 layers, conventions exist to mirror, scope is one PR, no mechanical oracle | **Feature** |
| 7 | Ambiguous after all checks | **Design-first** (safer to over-think) |

Print the classification with the signals that fired, then proceed (the user
types ABORT if it's wrong — don't interview them about it).

### Mechanical path
A proven tracer + a mechanical oracle are *jointly* required. Write a brief whose
acceptance criteria include "oracle passes N/N" and "PR cites the oracle
evidence + the tracer". The hard gate: `/execute` must NOT ship if the oracle is
below full pass. Do not clone, run the oracle, or branch inside `/scope` — the
brief is the deliverable.

### Feature path
1. **Explore first (parallel, one message).** Fire a few read-only Explore
   agents at once: the core module the change touches; the *adjacent* module
   that might already do "kind of the same thing" (decide subsume/extend/coexist);
   the data shape the feature consumes; the canonical write/endpoint pattern to
   mirror; (optional) the UI/wiring pattern. Do not emit planning text before
   this — explore-first prevents premature assumptions.
2. **Surface spec drift (batched judgment calls).** Before writing the brief,
   check: naming collisions, semantic overlap with the adjacent module, abstract
   verbs in the request ("reconcile", "bulk merge") that need a concrete
   operation, and which existing convention the new code mirrors. If any is a
   real judgment call, batch them into ONE question. If all resolve cleanly,
   proceed — quiet success is success.
3. **Write the brief**, label, hand off.

### Bug-fix path
Reproduction pre-flight only. Build the smallest deterministic pass/fail loop
(failing test seam, replay, bisect, differential). The brief requires the
executor's first commit to add the failing regression test, a later commit to
fix it, and the full suite to pass. If no loop can be built, label `needs-info`
and ask for the minimum missing input — do NOT branch, fix, or escalate to
design-first; un-reproducible bugs are awaiting-info work.

### Design-first path
Route through your design/planning skills (grill / brainstorm / interface design
/ PRD → issues) to break the work into verifiable vertical slices, then write an
Agent Brief per slice. **Stops at filed issues with briefs — do NOT implement.**

## Output conventions

- **Issue references**: first mention in a session includes the title
  (`#159 "rest_seconds persistence"`); later mentions can be bare `#159`. In
  durable artifacts (briefs, PR bodies, handoffs) ALWAYS include the title — they
  are read days later.
- **AI disclaimer**: every comment/issue body `/scope` posts starts with
  `> *This was generated by AI.*` — an audit trail for who wrote what.
- **Risk-level floor**: any ticket above the lowest risk level goes through the
  full contract-first process (classify → pre-flight → brief → label), even if
  the diff looks tiny. Lowest-risk one-line config/doc tweaks can skip straight
  to direct edit.

## Red flags — STOP

- Classifying Mechanical with no proven tracer, or skipping the oracle because
  "the diff is mechanical" — that is exactly when you need the oracle.
- Marking `ready-for-agent` without an Agent Brief — the runner then has no
  contract.
- Implementing inside ANY `/scope` path — every path stops at the contract;
  `/execute` owns execution.
- Feature path: skipping the spec-drift check, or emitting planning text before
  the Explore agents — that check IS the gate against vibe-coding.
- Bug-fix path: shipping a fix with no failing-test commit — the test is the
  regression guard.
- Storing a guessed merge disposition — store only the risk-level fact; the
  AFK/HITL merge call is made at diff time by `/execute`.

## See also

- [`../execute/SKILL.md`](../execute/SKILL.md) — the executor that consumes the brief
- [`../conduct/SKILL.md`](../conduct/SKILL.md) — the conductor that drives scope → execute
- [`../../templates/agent-brief.md`](../../templates/agent-brief.md) — the contract schema
- [`../../docs/concepts.md`](../../docs/concepts.md) — AFK/HITL rubric + the two-phase model
