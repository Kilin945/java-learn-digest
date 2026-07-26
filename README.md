# Java Learn Digest 📘

每天早上自動寄一封 5 分鐘可讀完的 Java / Spring Boot 學習信：依 `syllabus.txt` 課綱「一個主題拆成數小步、一天走一步」循序漸進，並用昨日複習做主動回想。沿用 macOS launchd 排程 → `claude -p` 依進度寫課 → Gmail SMTP 寄信。

## 運作
產生（prepare）在本機、寄出（send）在雲端，用 git 當同步通道，寄信不再靠筆電醒著。
```
本機 launchd（prepare，需要 claude）：
  git pull（取得雲端推進的進度）
  → build_lesson.py 依 progress.json 找出今日主題與第幾步、撈昨日重點
  → claude -p（prompt_daily）→ 回傳 JSON → apply_result.py --to-outbox 存進 outbox
  → git push（把備好的下一篇推上 GitHub）

GitHub Actions（send，免費雲端 cron，見 .github/workflows/daily-send.yml）：
  marker 命中？秒跳過 → apply_result.py --outbox-html → send_email.py 寄出
  → apply_result.py --commit-outbox 推進度、寫 lessons/<date>.md、打 marker
  → sync_notion.py 建 Notion 子頁面（去重、失敗不影響信）→ git push 把進度推回 repo
```
**每週回顧（weekly，同架構）**：本機**週五**備稿（`prepare-weekly`：build_lesson.py 把回顧視窗釘在「上週六～週五」7 篇 → claude → 存 weekly outbox → push state 分支），雲端**週六 08:00** 跟每日信同班次寄出（`weekly-<ISO週>` marker 一週只寄一次）。週六的備稿班是補救用，早上已寄成就會看到 marker 直接跳過。

### 時刻表

本機備稿 **12:00 / 13:00**（`run_slot.sh`，一個 job 依序跑每日與每週，避免兩個 job 搶 git lock），
雲端寄出 **08:00 / 14:00**：

| 時間 | 誰 | 做什麼 |
|---|---|---|
| 08:00 | 雲端 | 寄出前一天備好的課；週六順帶寄週報 |
| 12:00 | 本機 | 備稿第一班——**唯一有 pmset 定時 FullWake 撐腰的班** |
| 13:00 | 本機 | 備稿補救班；失敗的話當下就寄警示信 |
| 14:00 | 雲端 | 當天最後一班：缺稿體檢 + 警示信 |

pmset 那組定時喚醒由隔壁的 `ai-news-digest/install.sh` 設定（`pmset repeat` 全機只能設一組，兩個專案共用 12:00 那次）。**改備稿時間要連它一起改**，否則那些班只會拿到 DarkWake、連 DNS 都解不到。

> **備的是明天的課。** 08:00 寄出後 outbox 就空了，當天 12:00/13:00 再填進下一篇。
> 所以 14:00 體檢時 outbox 是空的，就等於明天早上會沒信——這是唯一能在「還來得及補」的時候
> 發現問題的檢查點，等到明天早上沒收到信才知道，已經是事發 25 小時後。

> 限制：outbox 一次只備「下一篇」；若筆電連續多天關著、prepare 沒機會補產，
> 雲端寄完庫存就會斷。要根治多日離線需把 outbox 改成小佇列（待辦）。

### 雲端寄信設定（GitHub Actions + Cloudflare 觸發）
1. repo 推上 GitHub（**私有**，因為 `state/`、`lessons/` 會進版控）。
2. 設 5 個 repo secrets：`GMAIL_USER`、`MAIL_TO`、`NOTION_PARENT_PAGE_ID`、
   `GMAIL_APP_PASSWORD`（= Keychain 的 app password）、`NOTION_TOKEN`。
3. 手動測試：Actions → daily-send → Run workflow → 勾 `test_send`（只寄測試信、不動狀態）。
4. 觸發（GMT+8，marker 去重一週期只寄一次）：由 Cloudflare Worker `digest-cron` 準點 `workflow_dispatch` — **08:00 主班**（寄前一天備好的課，週六順帶寄週報）、**14:00 最後一班**（`slot=last`，做缺稿體檢並寄警示信）。GitHub 自家 schedule 已移除（延遲久、會整班丟失）。改時間見 `~/Workspace/digest-cron`（`wrangler.toml` 的 cron 與 `src/index.js` 的 TARGETS key 必須一字不差）。

### 出事的時候你什麼時候會知道

| 失敗情況 | 警示信時間 | 誰寄的 |
|---|---|---|
| 有網路，但 claude 失敗 / 拿不到課程資料 | **13:00 當下** | 本機直寄，最即時 |
| 沒網路、筆電整天沒開 | **14:00** | 雲端體檢信（本機寄不出任何東西） |

兩層用 `state/alert-<mode>-YYYY-MM-DD` marker 去重，不會收到兩封。本機寄信失敗就不寫 marker，雲端自然接手。

每個備稿時段都會在 `run.log` 留一行 `RESULT prepare FAIL 網路未就緒`。**沒有這行就代表那個時段根本沒被觸發**（機器沒醒），跟「跑了但失敗」是兩回事。出事那天這些行會被彙整成 `state/attempts-YYYY-MM-DD.log` 推上 state 分支，直接附在警示信裡；連這個檔都沒有，就代表本機一次都沒能連上 GitHub。

## 安裝
1. `cp config.env.example config.env`，填入 `GMAIL_USER`、`MAIL_TO`、`LEARN_GOAL`。
2. 把 Gmail App Password 存進 Keychain：
   `security add-generic-password -a "$GMAIL_USER" -s "java-learn-gmail" -w`
3. `./install.sh` 安裝排程。
4. 立即測試：`zsh run_learn.sh daily`

## 課綱
編輯 `syllabus.txt`（一行一主題，`#` 為註解/分章）。想跳過某主題就刪掉或註解該行。

## 自動同步到 Notion
每天寄信成功後，`sync_notion.py` 會把該課建成 Notion「Spring 學習筆記」頁面底下的一個**子頁面**（標題＝`日期 · 主題`）。內建去重：同日已存在就跳過，重跑安全。背景排程用不了互動式 Notion MCP，所以走 **Notion 內部整合 (internal integration) + REST API**。

一次性設定：
1. 到 <https://www.notion.so/my-integrations> → New integration（internal）→ 複製 token（`ntn_...`）。
2. 打開 Notion「Spring 學習筆記」頁面 → 右上 `•••` → Connections → 加入剛建的整合（**沒分享頁面，API 會 404**）。
3. 把 token 存進 Keychain：
   `security add-generic-password -a "$GMAIL_USER" -s "java-learn-notion" -w`
4. `config.env` 填 `NOTION_PARENT_PAGE_ID`（「Spring 學習筆記」頁面 ID）。
5. 測試：`python3 sync_notion.py --md lessons/<date>.md --date <date>`

不設 `NOTION_PARENT_PAGE_ID` / token 則略過同步（不影響寄信）。

## 檔案
| 檔案 | 作用 |
|------|------|
| `syllabus.txt` | 課綱 |
| `build_lesson.py` | 依進度組 claude 的輸入 |
| `apply_result.py` | 解析結果、寄成功才更新進度與存檔 |
| `send_email.py` | Gmail SMTP 寄信 |
| `sync_notion.py` | 把 `lessons/<date>.md` 同步成 Notion 子頁面（REST API、去重） |
| `run_learn.sh` | 主流程 |
| `prompt_daily.txt` / `prompt_weekly.txt` | claude 指令 |
| `state/` | 進度、歷史、marker |
| `lessons/` | 每課 markdown 存檔 |

## 測試
`python3 -m pytest -v`
