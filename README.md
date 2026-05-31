# LY-workflow

> 一套指揮一群 AI 寫程式代理人的兩階段工作流，作者本人不會寫程式。
> A two-phase workflow for directing a swarm of AI coding agents — written by
> someone who does not write code.

**中文** · [English](#english)

核心想法：**會不會寫程式不是重點。** 重點是把「你要什麼」講到精確、可驗收，
再在 AI 動工時盯緊它別亂跑。這四個可組合的 skill，就是把這個想法變成能跑的東西。

緣起：[「不會寫 code 的醫師，怎麼架構一批臨床專案」部落格文章](https://liyangchen.me/blog/physician-as-architect)。

## 四個 skill

| Skill | 層級 | 做什麼 |
|---|---|---|
| [`/scope`](skills/scope/SKILL.md) | **計畫** | 把一句話的需求拆成 N 張*可驗收*的契約（Agent Brief）。每條驗收標準都標上 `[AFK]`（agent 自己做自己驗）或 `[HITL]`（要你親自簽名）。完全不寫 code。 |
| [`/execute`](skills/execute/SKILL.md) | **執行** | 把一張契約從頭跑到底：一個 **runner** 寫、一個**不同模型的 reviewer** 審，最多退回 3 次，然後開 PR。 |
| [`/conduct`](skills/conduct/SKILL.md) | **指揮** | 最上層的指揮者：讀原始需求、叫一次 `/scope`，再依序對每張契約跑 `/execute`。只持有 artifact，不抓任何工作 context。 |
| [`/spawn`](skills/spawn/SKILL.md) | **原語** | 把一個全新的 agent（Claude 或 Codex）開成 **tmux 裡的 live TUI**，讓每張票都有乾淨的 context，你也能 attach 旁觀。 |

## 怎麼串起來

```
/conduct ── 讀你的需求、包辦行政手續，只在真的需要決定時才丟回給你
   │
   ├─ /scope    一句話需求 ─────▶ N 張可驗收的契約（Agent Brief）
   │
   └─ /execute  一張契約 ───────▶ runner + reviewer（不同模型）──▶ PR
        │
        └─ /spawn   底層的 tmux 層，給每個 agent 乾淨的 context
```

兩個概念撐起整套：

1. **可驗收的契約。**「最後這格會產出 ooxx」agent 自己就能對答案；「把排程功能加好」
   不行。每條驗收標準都必須是前者那種。
2. **跨模型審查。** 寫的人和審的人刻意用**不同**模型家族 —— 同一個模型審自己寫的東西，
   會帶著同樣的盲點放水。

## 延伸閱讀

- [`docs/concepts.md`](docs/concepts.md) —— 完整的兩階段模型、AFK/HITL 判準、3 次退回規則、
  為什麼乾淨 context 很重要。
- [`docs/spawning-agents.md`](docs/spawning-agents.md) —— tmux 的 know-how：怎麼 spawn
  Claude/Codex 才會真的開起來並吃進 prompt（macOS + WSL）。
- [`INSTALL.md`](INSTALL.md) —— 寫給 **AI agent** 看的安裝指引，讓它幫你裝好。

## 安裝

最簡單的方式：**叫你的 AI agent 讀 [`INSTALL.md`](INSTALL.md) 幫你裝。** 把這句貼給它：

> 請依照這份指引安裝並設定 LY-workflow：
> https://raw.githubusercontent.com/liyoungc/LY-workflow/refs/heads/main/INSTALL.md

它會自己：clone 這個 repo → 檢查前置（`tmux` ≥ 3.3、`claude`/`codex`、`git`、`gh`）→ 把
`skills/*` 複製到你的 skills 目錄 → 設好可執行權限 → 跑一個 hello pane 的 smoke test →
確認四個指令都載入了。（已經 clone 在本機的話，直接叫它讀本機的 `INSTALL.md` 也行。）

想自己手動裝？INSTALL.md 末尾有完整逐步指令與一行搞定的 one-liner。

## 授權

MIT —— 見 [`LICENSE`](LICENSE)。

---

## English

Built around one idea: **whether you can write code is not the point.** The point
is stating what you want precisely and verifiably, then keeping the agents honest
while they build it. Four composable skills make that idea executable.

Background story: [physician-as-architect blog post](https://liyangchen.me/blog/physician-as-architect).

### The four skills

| Skill | Layer | What it does |
|---|---|---|
| [`/scope`](skills/scope/SKILL.md) | **Plan** | Turns a one-line problem into N *verifiable* contracts (Agent Briefs). Tags every acceptance criterion `[AFK]` (agent does it) or `[HITL]` (you sign off). Writes no code. |
| [`/execute`](skills/execute/SKILL.md) | **Execute** | Runs one contract end to end: a **runner** writes, a **model-diverse reviewer** checks, bounce back ≤ 3 times, then ship the PR. |
| [`/conduct`](skills/conduct/SKILL.md) | **Conduct** | The conductor on top: reads the raw request, spawns `/scope` once, then drives `/execute` over each contract in order. Holds only artifacts, never working context. |
| [`/spawn`](skills/spawn/SKILL.md) | **Primitive** | Launches a fresh agent (Claude or Codex) as a **live TUI in tmux**, so each ticket gets a clean context and you can attach to watch. |

### How it fits together

```
/conduct ── reads your request, runs the admin, only pings you for real decisions
   │
   ├─ /scope    problem ─────────▶ N verifiable contracts (Agent Briefs)
   │
   └─ /execute  one contract ────▶ runner + reviewer (different models) ──▶ PR
        │
        └─ /spawn   the tmux layer that gives each agent a clean context
```

Two ideas do most of the work:

1. **Verifiable contracts.** "The last cell produces output X" can be checked by
   the agent itself. "Add the scheduling feature" can't. Every acceptance
   criterion has to be the first kind.
2. **Cross-model review.** The writer and the reviewer run on *different* model
   families on purpose — a model reviewing its own output shares its own blind
   spots.

### Read more

- [`docs/concepts.md`](docs/concepts.md) — the full two-phase model, the AFK/HITL
  rubric, the 3-strike rule, why clean context matters.
- [`docs/spawning-agents.md`](docs/spawning-agents.md) — the tmux know-how: how to
  spawn Claude/Codex so it actually boots and takes its prompt (macOS + WSL).
- [`INSTALL.md`](INSTALL.md) — an install guide written for an **AI agent** to set
  this up for you.

### Install

Easiest path: **tell your AI agent to read [`INSTALL.md`](INSTALL.md) and do it.**
Paste this to it:

> Install and configure LY-workflow by following this guide:
> https://raw.githubusercontent.com/liyoungc/LY-workflow/refs/heads/main/INSTALL.md

The agent will: clone the repo → check prerequisites (`tmux` ≥ 3.3,
`claude`/`codex`, `git`, `gh`) → copy `skills/*` into your skills dir → make the
scripts executable → run a hello-pane smoke test → confirm the four commands load.
(If you've already cloned the repo, just point it at your local `INSTALL.md`.)

Prefer to do it by hand? INSTALL.md ends with the full step-by-step plus a one-liner.

### License

MIT — see [`LICENSE`](LICENSE).
