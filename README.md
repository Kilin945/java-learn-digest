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
**每週回顧（weekly，同架構）**：本機**週五**備稿（`prepare-weekly`：build_lesson.py 把回顧視窗釘在「上週六~週五」7 篇 → claude → 存 weekly outbox → push state 分支），雲端**週六**早上跟每日信同時段寄出（`weekly-<ISO週>` marker 一週只寄一次）。週五沒開機有週六/日/週一備援，整週末沒開則下週一補產、雲端隔天補寄，內容永遠是完整的「週六~週五」那一週。
> 限制：outbox 一次只備「下一篇」；若筆電連續多天關著、prepare 沒機會補產，
> 雲端寄完庫存就會斷。要根治多日離線需把 outbox 改成小佇列（待辦）。

### 雲端寄信設定（GitHub Actions）
1. repo 推上 GitHub（**私有**，因為 `state/`、`lessons/` 會進版控）。
2. 設 5 個 repo secrets：`GMAIL_USER`、`MAIL_TO`、`NOTION_PARENT_PAGE_ID`、
   `GMAIL_APP_PASSWORD`（= Keychain 的 app password）、`NOTION_TOKEN`。
3. 手動測試：Actions → daily-send → Run workflow → 勾 `test_send`（只寄測試信、不動狀態）。
4. 排程（GMT+8，marker 去重一週期只寄一次）：每日 07:55 / 08:55 / 10:25 / 11:55 / 13:55；每週回顧週六同時段寄出。

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
