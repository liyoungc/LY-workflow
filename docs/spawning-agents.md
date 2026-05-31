# Spawning agents in tmux — 怎麼把 agent 開起來 / the know-how

**中文** · [English](#english)

這是最多人做錯的環節：怎麼從一個 AI agent 穩穩地開出另一個——讓它真的 boot、吃進 prompt、又能被
旁觀。隨附的 `skills/spawn/spawn-mac.sh` 把 macOS/Linux 這套全包好了；這份文件解釋每塊*為什麼*在那，
並給出 Windows/WSL 的模式（我們只記錄、不附腳本，因為它跟環境綁很死）。

## 為什麼用 tmux、為什麼跑 live TUI

- **Context 隔離。** 每張票跑在自己的全新 agent process。長壽的 agent 做多張票會隨 context 塞滿而
  退化；一票一個新 process 讓每個都最銳利。
- **agent 之間看得到、傳得了訊息。** 同一個 tmux session 裡的 pane 能互讀、互相 `send-keys`。lead
  把 prompt 交給 runner；runner 可以戳 reviewer。這種互通有時正是你要的。
- **attach 來看，detach 就放著。** `tmux attach -t <session>` 是任一 pane 的即時視窗；detach 後它
  照跑。你可以靠在 pane 間切換來監督四個 agent。
- **會存活。** tmux session 的壽命超過你啟動它的那個終端機，所以闔上筆電/斷線後批次照跑。
- **開真的 TUI，不是 headless。** 用互動式 binary（`claude`、`codex`），**不要** `claude -p` /
  `codex exec`。spawn 出來的 agent 必須載入完整 skills 與 hooks；一次性的 headless 模式會跳過那些，
  你會得到一個殘廢的 agent。

## macOS / Linux — 簡單的那邊

`spawn-mac.sh` 組出 tmux 指令、在 pane 裡跑 agent。讓它無痛的關鍵只有一個：**所有 shell quoting 都由
`printf %q` 解決。** prompt 在塞進內層指令前先過一次 `printf %q`，所以任何字元——`;` `'` `"` `$`、
反引號、換行、UTF-8——都安全。prompt 內容毫無限制。

Claude：
```bash
# （概念上 spawn-mac.sh 做的事）
INNER="$(printf '%q' "$CLAUDE_BIN") $(printf '%q' "$PROMPT")"
tmux new-window -t "${SESSION}:" -n "$TITLE" -c "$CWD" "$INNER"
```

macOS 上的 Codex——它沒有 `/bg` 之類的背景模式，所以就在新視窗裡當一般前景 process 跑。
`codex -C <cwd>` 設工作目錄；prompt 是結尾的 positional：
```bash
INNER="$(printf '%q' "$CODEX_BIN") -C $(printf '%q' "$CWD") $(printf '%q' "$PROMPT")"
tmux new-window -t "${SESSION}:" -n "$TITLE" -c "$CWD" "$INNER"
```

## Windows / WSL — 脆弱的那邊（模式，非附帶腳本）

Windows 上穩的路是用 **WSL 的原生 tmux** 透過 `cmd.exe` interop 去驅動 Windows 的 agent binary。
三件事會咬人，照順序：

**1. `cmd.exe` interop 會吃掉反斜線。** 當 bash → `cmd.exe` 鏈傳一個帶引號的參數時，裡面的反斜線會
被吃掉。所以任何你交給 `cmd.exe` 的執行檔路徑都必須用**正斜線**：
```
cmd.exe /c "C:/path/to/pwsh.exe" -NoProfile -File "C:/path/to/wrapper.ps1"
#            ^ 正斜線，不是 C:\path\to\pwsh.exe
```

**2. prompt 的 quoting 是地雷——所以別 quote，用檔案。** 把 prompt 塞進 `pwsh -Command` 字串時，
有兩個字元特別會炸：

| 字元 | 為什麼炸 | 症狀 |
|---|---|---|
| `;` | 在終端層被當成指令分隔 | prompt 變兩段指令；狀態錯掉，常常看不出來 |
| `'` | 提早終結單引號內層字串 | prompt 被截斷或語法錯誤 |

解法：**把 prompt 寫進檔案**，讓 wrapper 原樣讀進來（PowerShell `Get-Content -Raw`）。檔案路徑不含
prompt 內容，所以沒東西要跳脫。prompt 裡的空白、引號、分號全變無害。

**3. 視窗 title 仍有限制。** 即使用了 file-based prompt，tmux 的**視窗 title** 仍不能含
`; ' " \` $`——tmux 拿它們當分隔。spawn 前先驗證 title；不合就明確拒絕，建議用 `,` 或破折號取代 `;`，
並避開縮寫（`it's` → `it is`）。

整條鏈的草圖：
```
bash (MSYS/git-bash)
  → wsl.exe -d <distro> -- tmux new-window -c /mnt/<drive>/<cwd> \
       cmd.exe /c "C:/.../pwsh.exe" -NoProfile -File "C:/.../<title>-spawn.ps1"
         → pwsh wrapper：設 env、Set-Location $cwd、
            $p = Get-Content -Raw "<title>-prompt.txt"
            & claude.exe $p     # 或 codex
```
從任何地方 attach：
```
wsl -d <distro> -- tmux attach -t <session>:<title>
```

## babysit — 確認 prompt 真的在跑

spawn 之後，你**並不知道** prompt 在跑。兩件事會悄悄把它吃掉：

1. **首次啟動的 trust dialog。** agent 第一次在某目錄跑時，可能跳出 workspace-trust / 權限對話框。
   那個 modal 在的時候，鍵盤輸入都進對話框——而以 argv positional 傳的 prompt 會在 modal 關掉時被丟掉。
2. **TUI 還在 boot**，輸入框還沒就緒。

`skills/spawn/lib/prompt-babysit.sh` 兩個都處理：它輪詢 pane，並

- 從**可見畫面**（不是 scrollback，scrollback 會留舊文字）偵測 trust dialog，按一次 Return，等
  完整 TUI 畫好，然後**重新注入原本的 prompt**；
- 只在看到活動跡象（spinner、`Working`、`Thinking`、`esc to interrupt`、token 數）或 prompt 文字
  被回顯時，才判定為「在跑」。

它回報 `PROMPT_CONFIRMED=yes` / `warning` / `n/a`。把 `warning` 當成「attach 去看一眼」，不是硬失敗。

對於你**空著**啟動的 session（沒帶 seed prompt——停在輸入框），同一支 library 可以在輸入框就緒後打
一個 TUI slash-command——例如 `_spawn_inject_effort` 會打 `/effort <level>` 並驗證它生效。那是讓
spawn 出的 session 用指定 reasoning effort 起跑的唯一方法，因為沒有對應的 CLI 旗標。

## 兩個各會浪費你一小時的陷阱

**送出用 `C-m`，不是具名的 `Enter`。** 以 Ink 為底的 TUI（Claude Code 與許多 Node TUI）不把
`tmux send-keys` 來的具名鍵 `Enter` 當送出。它們吃 `C-m`。如果你 `send-keys 'something' Enter` 而
prompt 就卡在輸入框，就是這個原因。

**純數字 tmux session 名會跟 `-t` 撞。** `tmux new-window -t "$S"` 裡 `$S` 是純數字（`1`、`10`）時，
會被當成*目前 session 裡的 window index*，而不是名叫 `1` 的 session——你會拿到
`create window failed: index N in use`，即使 session N 存在。永遠加結尾冒號：
`tmux new-window -t "${S}:"` 強制 session-target 解讀，並挑下一個空 index。`spawn-mac.sh` 到處都這麼做。

## 看一個批次

- `tmux attach -t <session>`，然後 `Ctrl-b w` 在 pane（lead / runner / reviewer）間切換。
- `tmux capture-pane -t <pane> -p` 非互動地讀一個 pane 的文字（只給人眼看——要*程式化*判斷完成，
  讀 worker 的 result 檔 + sentinel，別用 scrape；scrollback 會掉字、會 race）。
- 用 `split-bottom-half` 再 `split-bottom-right` 的 layout，把 lead + runner + reviewer 排在同一個
  視窗（見 `spawn-mac.sh --layout`）。

---

## English

This is the part people get wrong the most: actually launching one AI agent from
another, reliably, so it boots, accepts its prompt, and can be watched. The
bundled `skills/spawn/spawn-mac.sh` encodes all of this for macOS/Linux; this doc
explains *why* each piece is there and gives the Windows/WSL pattern (which we
document rather than ship, because it's environment-specific).

### Why tmux, and why a live TUI

- **Context isolation.** Each ticket runs in its own fresh agent process. A
  long-lived agent doing many tickets degrades as its context fills; a new
  process per ticket keeps each one sharp.
- **Agents can see and message each other.** Panes in one tmux session can read
  and `send-keys` to each other. A lead hands a prompt to a runner; a runner can
  poke a reviewer. That cross-talk is sometimes exactly what you want.
- **Attach to watch, detach to leave alone.** `tmux attach -t <session>` is a
  live window onto any pane; detaching leaves it running. You can supervise four
  agents by flipping between panes.
- **Survives.** A tmux session outlives the terminal you launched it from, so a
  batch keeps running after you close the laptop lid / disconnect.
- **Launch the real TUI, not the headless mode.** Use the interactive binary
  (`claude`, `codex`), NOT `claude -p` / `codex exec`. The spawned agent must
  load its full skills and hooks; the one-shot headless modes skip that and you
  get a crippled agent.

### macOS / Linux — the easy case

`spawn-mac.sh` builds a tmux command and runs the agent inside a pane. The one
thing that makes it painless: **all shell quoting is solved by `printf %q`.** The
prompt is round-tripped through `printf %q` before being embedded in the inner
command, so any character — `;` `'` `"` `$`, backticks, newlines, UTF-8 — is
safe. No constraints on prompt content.

Claude:
```bash
# (conceptually, what spawn-mac.sh does)
INNER="$(printf '%q' "$CLAUDE_BIN") $(printf '%q' "$PROMPT")"
tmux new-window -t "${SESSION}:" -n "$TITLE" -c "$CWD" "$INNER"
```

Codex on macOS — it has no `/bg`-style background mode, so just run it as a
normal foreground process in a new window. `codex -C <cwd>` sets the working
directory; the prompt is the trailing positional:
```bash
INNER="$(printf '%q' "$CODEX_BIN") -C $(printf '%q' "$CWD") $(printf '%q' "$PROMPT")"
tmux new-window -t "${SESSION}:" -n "$TITLE" -c "$CWD" "$INNER"
```

### Windows / WSL — the fragile case (pattern, not a shipped script)

On Windows the robust path is **WSL's native tmux** driving the Windows agent
binary through `cmd.exe` interop. Three things bite, in order:

**1. `cmd.exe` interop eats backslashes.** When a bash → `cmd.exe` chain passes a
quoted argument, backslashes inside it are stripped. So any executable path you
hand to `cmd.exe` must use **forward slashes**:
```
cmd.exe /c "C:/path/to/pwsh.exe" -NoProfile -File "C:/path/to/wrapper.ps1"
#            ^ forward slashes, not C:\path\to\pwsh.exe
```

**2. Prompt quoting is a minefield — so don't quote, use a file.** Embedding the
prompt inside a `pwsh -Command` string breaks on two characters specifically:

| Char | Why it breaks | Symptom |
|---|---|---|
| `;` | parsed as a command separator at the terminal layer | the prompt fires as two commands; wrong state, often invisible |
| `'` | terminates the single-quoted inner string early | truncated prompt or a syntax error |

The fix: **write the prompt to a file** and have the wrapper read it raw
(PowerShell `Get-Content -Raw`). The file path carries no prompt content, so
there's nothing to escape. Spaces, quotes, semicolons in the prompt all become
harmless.

**3. The window title still has constraints.** Even with a file-based prompt, the
tmux **window title** must not contain `; ' " \` $` — tmux uses them as
separators. Validate the title before spawning; refuse with a clear message and
suggest `,` or an em-dash instead of `;`, and avoiding contractions (`it's` →
`it is`).

Sketch of the chain:
```
bash (MSYS/git-bash)
  → wsl.exe -d <distro> -- tmux new-window -c /mnt/<drive>/<cwd> \
       cmd.exe /c "C:/.../pwsh.exe" -NoProfile -File "C:/.../<title>-spawn.ps1"
         → pwsh wrapper: set env, Set-Location $cwd,
            $p = Get-Content -Raw "<title>-prompt.txt"
            & claude.exe $p     # or codex
```
Attach from anywhere with:
```
wsl -d <distro> -- tmux attach -t <session>:<title>
```

### The babysit — confirming the prompt actually runs

After you spawn, you do **not** know the prompt is running. Two things silently
swallow it:

1. **The first-launch trust dialog.** On an agent's first run in a new directory
   it may show a workspace-trust / permission prompt. While that modal is up,
   keystrokes go to the dialog — and a prompt passed as an argv positional is
   dropped when the modal dismisses.
2. **The TUI is still booting** and the input box isn't ready.

`skills/spawn/lib/prompt-babysit.sh` handles both: it polls the pane, and

- detects a trust dialog on the **visible screen** (not scrollback, which keeps
  stale text), presses Return once, waits for the full TUI to draw, then
  **re-injects the original prompt**;
- confirms "running" only when it sees activity (a spinner, `Working`,
  `Thinking`, `esc to interrupt`, token counts) or the prompt text echoed back.

It reports `PROMPT_CONFIRMED=yes` / `warning` / `n/a`. Treat `warning` as "attach
and look", not a hard failure.

For a session you launch **bare** (no seed prompt — lands at the input box), the
same library can type a TUI slash-command after the box is ready — e.g.
`_spawn_inject_effort` types `/effort <level>` and verifies it registered. That's
the only way to start a spawned session at a given reasoning effort, since
there's no CLI flag for it.

### Two gotchas that waste an hour each

**Submit with `C-m`, not the named `Enter`.** Ink-based TUIs (Claude Code and
many Node TUIs) ignore the named key `Enter` from `tmux send-keys`. They submit
on `C-m`. If you `send-keys 'something' Enter` and the prompt just sits in the
input box, this is why.

**Integer tmux session names collide with `-t`.** `tmux new-window -t "$S"` where
`$S` is a pure integer (`1`, `10`) is parsed as a *window index in the current
session*, not as the session named `1` — you get `create window failed: index N
in use` even though session N exists. Always use a trailing colon:
`tmux new-window -t "${S}:"` forces session-target interpretation and picks the
next free index. `spawn-mac.sh` does this everywhere.

### Watching a batch

- `tmux attach -t <session>` then `Ctrl-b w` to flip between panes (lead / runner
  / reviewer).
- `tmux capture-pane -t <pane> -p` to read a pane's text non-interactively (for
  human eyes only — for *programmatic* completion detection, read the worker's
  result file + sentinel, not a scrape; scrollback is lossy and racy).
- Lay out a lead + runner + reviewer in one window with the `split-bottom-half`
  then `split-bottom-right` layouts (see `spawn-mac.sh --layout`).
