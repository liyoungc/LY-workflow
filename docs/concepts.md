# Concepts — the two-phase agent workflow

This is the design behind the four skills. You can read it without installing
anything; the skills are just this philosophy made executable.

The premise: **whether you can write code is not the bottleneck.** The bottleneck
is stating, precisely and verifiably, what you want — and then keeping a swarm of
agents honest while they build it. The whole system splits into two phases with a
thin conductor on top.

```
        ┌─────────────────────────── /conduct ───────────────────────────┐
        │  reads the raw request, runs the admin, only interrupts you when │
        │  a real human decision surfaces. Holds only artifacts.           │
        └───────────────┬──────────────────────────────┬─────────────────┘
                        │                              │
                ┌───────▼────────┐            ┌────────▼────────┐
                │    /scope      │            │    /execute     │
                │  PLAN phase    │  contract  │  EXECUTE phase  │
                │  problem → N   ├───────────▶│  one ticket →   │
                │  verifiable    │  (Agent    │  shipped PR     │
                │  contracts     │   Brief)   │                 │
                └────────────────┘            └───────┬─────────┘
                                                      │ spawns
                                              ┌───────▼─────────┐
                                              │     /spawn      │
                                              │  tmux: runner + │
                                              │  reviewer panes │
                                              └─────────────────┘
```

## Phase 1 — Plan (`/scope`)

A request usually arrives as one sentence ("make the report auto-summarize
trends"). That is a wish, not a project. Planning is two moves:

**1. Break it into tickets.** Each ticket small enough to finish on its own,
verify on its own, and not block on another half-done ticket.

**2. For each ticket, separate the decisions.** Not "how do I write this" but
"which calls here are mine, and which can the agent just make?" Data correctness,
privacy boundaries, whether a field is shown at all — yours. Variable names,
which library, how a function is split — the agent's; you'd manage those worse
than it does.

That split is written straight into the spec as a tag on every acceptance
criterion: `[AFK]` (Away From Keyboard — the agent does it and verifies it,
no sign-off needed) or `[HITL]` (Human In The Loop — only counts once you sign).

The output is an **Agent Brief**: a contract whose every acceptance criterion is
**verifiable** — concrete enough that the agent can check its own answer when
done. "The last cell produces output X" is verifiable. "Add the scheduling
feature" is not. The whole plan phase happens in issues and markdown; not one
line of code is touched.

### The AFK / HITL rubric

A criterion is **HITL** if any of these fire (when unsure, choose HITL — being
over-cautious is recoverable; under-cautious ships breakage):

1. **Sensitive data** — reads/writes data a person would act on directly and
   wrongly if it's wrong (personal data, money, health, anything privacy- or
   safety-bearing).
2. **Schema / data migration** — a column added/dropped/retyped on a production
   table.
3. **Audit / logging invariant** — changing how an audit trail is written,
   redacted, or rotated.
4. **New external surface** — a new public endpoint, auth path, or side-effecting
   public flag.
5. **Cross-service change** — touches more than one critical service.
6. **First use of a new pattern** with no proven tracer to clone, landing on a
   sensitive surface.
7. **Major-surface refactor** — many production files, or any file on a path you
   flagged as sensitive/critical.
8. **You said so** — a `needs-review` label, or the brief says "human review
   required".

Otherwise the criterion is **AFK-safe**.

**Risk level** is a per-repo fact, orthogonal to the per-criterion tag: level 1
(docs/config), level 2 (tooling, non-critical), level 3 (sensitive / critical
path). A level-3 repo can still have AFK criteria — but its *PR* may still be
HITL-gated at merge. Three independent axes: who does the work (label), which
criteria need sign-off (tag), whether the resulting PR auto-merges (gate).

## Phase 2 — Execute (`/execute`)

Turning a contract into running code, one ticket at a time. Four rules carry the
weight:

**Clean context per ticket.** One agent doing several tickets in a row goes dull
— the earlier work clogs its context and its judgment drifts. So each ticket
starts a fresh agent. In-progress state lives in a durable note; whoever picks up
reads it and continues. (This is why the system leans on tmux — see
[`spawning-agents.md`](spawning-agents.md).)

**One writes, another reviews — on different models.** The writer (runner) hands
off; a separate reviewer checks it, and the two run on *different model
families* on purpose (a Claude-written diff goes to a Codex reviewer, and vice
versa). The reviewer defaults to skeptical — it has to find nothing wrong before
it passes. Same-model self-review shares the same blind spots and waves its own
mistakes through.

**Information flows top-down only.** You see what the runner and reviewer are
doing; they don't see you, and they don't see each other's full context. So the
runner builds to the spec instead of trying to guess "what they *really* meant".

**Bounce back at most three times.** Reviewer rejects → runner fixes → re-review.
But if the same ticket fails three rounds, stop. That almost always means the
spec has something you didn't think through — time for you to look, not to tell
the agent to try a fourth time.

When a ticket lands, write a handoff and open the next ticket's fresh context.
One after another.

## The conductor (`/conduct`)

The execute loop is fiddly: someone has to keep confirming, copying a prompt into
the next window, checking what merged. A human babysitting it burns the day on
clerical work. So a conductor wraps the whole thing:

1. **Read the request** — the raw human ask.
2. **Get it scoped** — hand it to `/scope` to become contracts.
3. **Run the admin** — drive `/execute` over each contract, in dependency order,
   one at a time.

If something genuinely needs a human, it surfaces that to you. Crucially, the
conductor **holds only artifacts** — the list of contract references and a
one-line result per reference, all re-derivable from the issue tracker. The heavy
working context stays inside the spawned sessions and dies with them. That's what
lets one conductor run a batch overnight without its own context filling up.

## Why "can you code" stops mattering

Once the writing is delegated, the time goes into saying what you want clearly
enough that an agent can't misread it — and into the verification scaffolding
(verifiable criteria, cross-model review, the 3-strike stop) that catches it when
it does. That's design and specification work, not typing.
