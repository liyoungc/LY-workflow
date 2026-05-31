# Concepts — 兩階段 agent 工作流 / the two-phase agent workflow

**中文** · [English](#english)

這是四個 skill 背後的設計。不用裝任何東西就能讀；skill 只是把這套理念變成能執行的形式。

前提：**會不會寫程式不是瓶頸。** 瓶頸是把「你要什麼」講到精確且可驗收，然後在一群 agent
動工時盯著它們別亂跑。整套系統拆成兩個階段，上面再加一層薄薄的指揮者。

```
        ┌─────────────────────────── /conduct ───────────────────────────┐
        │  讀原始需求、包辦行政、只在真的需要決定時才丟回給你。只持有 artifact。│
        └───────────────┬──────────────────────────────┬─────────────────┘
                        │                              │
                ┌───────▼────────┐            ┌────────▼────────┐
                │    /scope      │            │    /execute     │
                │   計畫階段      │  契約       │   執行階段       │
                │  問題 → N 張    ├───────────▶│  一張票 →       │
                │  可驗收契約     │ (Agent     │  shipped PR     │
                │                │  Brief)    │                 │
                └────────────────┘            └───────┬─────────┘
                                                      │ spawn
                                              ┌───────▼─────────┐
                                              │     /spawn      │
                                              │  tmux：runner + │
                                              │  reviewer panes │
                                              └─────────────────┘
```

## 第一階段 — 計畫（`/scope`）

需求進來通常是一句話（「讓 report 自動把趨勢整理出來」）。那是個願望，不是專案。計畫就兩個動作：

**1. 拆成一張一張票。** 每張小到能單獨做完、單獨驗、不會卡在另一張還沒做完的票上。

**2. 對每張票，把決定權分開。** 問的不是「這要怎麼寫」，而是「這裡面哪些只有我能拍板、哪些
agent 自己定就好？」資料正不正確、隱私邊界、某欄位要不要顯示——你的。變數叫什麼、用哪個
library、function 怎麼切——agent 的；你管反而管得比它差。

這個區分直接寫進規格，當作每條驗收標準前面的標籤：`[AFK]`（Away From Keyboard——agent 自己做、
自己驗，不用回頭找你）或 `[HITL]`（Human In The Loop——要你簽名才算數）。

產出是一份 **Agent Brief**：一份契約，它的每一條驗收標準都**可驗證**——具體到 agent 做完能自己
對答案。「最後這格會產出 X」可驗證；「把排程功能加好」不行。整個計畫階段都在 issue 和 markdown
裡打轉，一行 code 都沒碰。

### AFK / HITL 判準

一條標準只要符合下列任一項，就是 **HITL**（拿不準時選 HITL——過度謹慎可回復，過度大膽會把東西
弄壞）：

1. **敏感資料** — 讀寫一旦出錯就會讓人據以做錯事的資料（個資、金錢、健康，任何牽涉隱私或安全的）。
2. **schema / 資料遷移** — 在 production 資料表上新增/刪除/改型欄位。
3. **稽核 / log 不變量** — 改動稽核軌跡怎麼寫、怎麼遮蔽、怎麼輪替。
4. **新對外介面** — 新的公開 endpoint、auth 路徑、有副作用的公開旗標。
5. **跨服務變更** — 動到一個以上的關鍵服務。
6. **首次採用新 pattern** 且沒有可複製的 tracer，又落在敏感面上。
7. **大面積重構** — 動到很多 production 檔，或任何你標為敏感/關鍵路徑的檔。
8. **你說了算** — 有 `needs-review` 標籤，或 brief 寫明「需人工審查」。

否則就是 **AFK-safe**。

**風險等級（risk level）** 是每個 repo 的屬性，跟「每條標準的標籤」正交：level 1（文件/設定）、
level 2（工具、非關鍵）、level 3（敏感／關鍵路徑）。level-3 的 repo 仍可以有 AFK 標準——但它的
*PR* 在合併時可能仍是 HITL-gated。三條互不相干的軸：誰做這件事（label）、哪些標準要簽名（tag）、
PR 要不要自動合（gate）。

## 第二階段 — 執行（`/execute`）

把契約變成跑得動的 code，一次一張票。四條規則撐起重量：

**每張票一個乾淨 context。** 同一個 agent 連做好幾張會鈍掉——前面的東西塞滿 context，判斷開始飄。
所以一張票一個新的 agent。進行中的狀態寫在一個耐久的交班檔；接手的讀一下就接得上。（這正是為什麼
整套靠 tmux——見 [`spawning-agents.md`](spawning-agents.md)。）

**一個寫、另一個審——而且用不同模型。** 寫的（runner）交出來後，另一個（reviewer）去審，兩個刻意
用*不同模型家族*（Claude 寫的丟給 Codex 審，反之亦然）。reviewer 預設找碴——挑不出問題才放行。
同模型自審帶著同樣盲點，常常把自己的錯放過去。

**資訊只能由上往下。** 你看得到 runner 跟 reviewer 在幹嘛；它們看不到你，也看不到對方的全貌。
這樣 runner 只照規格做，不會去猜「他其實是不是想要別的」。

**退回最多三次。** reviewer 退回 → runner 改 → 再審。但同一張票來回三次還過不了，就停。那幾乎都
代表規格裡有你沒想清楚的東西——這時該你進去看，而不是叫它試第四次。

一張票收掉，寫交班，開下一張的新 context。一張接一張。

## 指揮者（`/conduct`）

執行迴圈很瑣碎：得有人不時回來按確認、把 prompt 複製到下一個視窗、檢查什麼合併了。讓人坐在電腦前
盯，一天就耗在文書工作上。所以包一層指揮者：

1. **讀需求** — 人類給的原始 ask。
2. **拿去 scope** — 交給 `/scope` 變成契約。
3. **跑行政** — 依相依順序、一次一張地對每張契約跑 `/execute`。

真的需要人類時，它會丟回給你。關鍵是：指揮者**只持有 artifact**——契約 ref 清單加每個 ref 一行
結果，全都能從 issue tracker 重建。沉重的工作 context 留在 spawn 出去的 session 裡、隨之消滅。
這就是為什麼一個指揮者能跑一整晚的批次而自己的 context 不會被塞爆。

## 為什麼「會不會寫 code」就不重要了

一旦把「寫」外包掉，時間就花在把需求講到 agent 不會誤讀，以及那些在它誤讀時抓得住它的驗證鷹架
（可驗證的標準、跨模型審查、3 次退回就停）。那是設計與規格的工作，不是打字。

---

## English

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

### Phase 1 — Plan (`/scope`)

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

#### The AFK / HITL rubric

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

### Phase 2 — Execute (`/execute`)

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

### The conductor (`/conduct`)

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

### Why "can you code" stops mattering

Once the writing is delegated, the time goes into saying what you want clearly
enough that an agent can't misread it — and into the verification scaffolding
(verifiable criteria, cross-model review, the 3-strike stop) that catches it when
it does. That's design and specification work, not typing.
