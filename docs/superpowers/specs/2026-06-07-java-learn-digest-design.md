# java-learn-digest 設計文件

> 建立日期：2026-06-07
> 狀態：設計定案，待寫實作計畫

## 1. 目的

讓 Java / Spring Boot 的知識「自動進到腦子」——每天早上收到一封 5 分鐘可讀完的學習信，依固定課綱循序漸進，並用「昨日複習」做主動回想，靠**持續性**把知識長進去。沿用 `ai-news-digest` 已驗證的可靠送信與排程機制，但內容層完全不同：新聞是往外抓 RSS，學習是依課綱進度請 `claude -p` 寫課。

## 2. 核心設計決定

| 決定 | 內容 |
|------|------|
| 與新聞 repo 的關係 | **獨立新專案**（做法 A）。`ai-news-digest` 一行不動、零回歸風險。複用其已泛用的送信腳本與 launchd/install 模式。 |
| 課綱來源 | `syllabus.txt`，**Claude 先產一版**、使用者隨時編輯。每天教「下一個還沒走完的小步」。 |
| 節奏 | **一個主題拆成數個小步、一天走一步**（不是一天一主題）。由 Claude 判斷主題講完了沒。核心訴求：持續、進步一點點。 |
| 教學調性 | **把學習者當完全不會的人教**。每個英文/技術術語第一次出現就定義；多用生活比喻；附「術語表」。 |
| 語言 | 英文為主 + 中文輔助（概念標題英文、解說中文主導）。 |
| 篇幅 | 5 分鐘小圈圈，一封只教一個小概念。 |
| 記憶機制 | 每封信 = 今日新小步 + 昨日複習（2~3 題主動回想，解答放信末，email-safe）。 |
| 節奏（發信） | 平日每日課；週日「本週回顧」混出跨整週的回想測驗。 |
| 內容來源 | v1 用 Claude 自身知識 + 每課附官方文件連結當查證錨點。**不做 grounding**（抓官方原文墊底）——列為日後可選強化。 |
| Notion | v1 每課**順手存一份本地 markdown**（`lessons/YYYY-MM-DD-<slug>.md`）。歸檔 Notion 採**半自動**：日後使用者開 Claude Code 手動觸發同步（互動情境下 Notion MCP 才可用）。排程 headless 流程**不碰 Notion**。 |
| 視覺 | 沿用柔和卡片版型 + 每日配色輪換，與新聞信一致質感。 |

## 3. 檔案結構

| 檔案 | 作用 | 對應新聞系統 |
|------|------|------|
| `syllabus.txt` | 排序課綱，一行一主題，`#` 分章/註解 | `feeds.txt` |
| `build_lesson.py` | 讀 `progress.json` 決定今日主題與第幾步、撈昨日重點，輸出給 claude 的 context 包；另含每日配色計算 | `fetch_feeds.py` |
| `prompt_daily.txt` / `prompt_weekly.txt` | 學習版指令（含 beginner 教學規則與輸出 JSON 格式） | `prompt*.txt` |
| `apply_result.py` | 解析 claude 輸出的 JSON、驗證、更新 `progress.json` 與 `last_lesson.json`、寫 markdown 存檔、把 html 輸出給送信 | （新）|
| `send_email.py` | 沿用 `ai-news-digest/send_ai_news.py`（內容無關，原封照搬） | `send_ai_news.py` |
| `run_learn.sh` | 主腳本：去重→build→claude→apply→驗證→送信→寫 marker | `run_ai_news.sh` |
| `install.sh` + `launchd/*.plist.template` | 沿用，調整排程時段 | 同名 |
| `config.env.example` / `config.env` | 設定（後者進 .gitignore） | 同名 |
| `requirements.txt` | 依賴（預計僅標準庫，無 feedparser） | 同名 |
| `state/` | `progress.json`、`last_lesson.json`、日/週 marker | `state/` |
| `lessons/` | 每課 markdown 存檔（供日後手動歸檔 Notion） | （新）|
| `tests/` | pytest | `tests/` |
| `README.md` | 專案說明 | `README.md` |

## 4. 狀態模型（state/）

`progress.json`
```json
{
  "current_index": 0,
  "current_topic": "IoC 與依賴注入（為什麼不要自己 new）",
  "step": 2,
  "covered": [
    "Day1：自己 new 會把類別和特定實作綁死，難換、難測"
  ],
  "completed_topics": [
    {"topic": "...", "finished": "2026-06-05", "steps": 4}
  ]
}
```

`last_lesson.json`（給明天出複習題）
```json
{
  "date": "2026-06-07",
  "topic": "IoC 與依賴注入",
  "step": 1,
  "summary": "自己 new 會把點餐服務和真實收款機綁死：難換、難測"
}
```

Markers：`state/sent-YYYY-MM-DD`（每日 exactly-once）、`state/sent-week-YYYY-Www`（每週）。

## 5. 每日資料流

```
launchd 多時段觸發
  → 今天寄過了？(daily marker) → 秒跳過
  → 等網路就緒
  → build_lesson.py：
       讀 syllabus.txt（排序主題）
       讀 progress.json → 目前主題、covered、step；若無進行中主題則取下一個
       讀 last_lesson.json → 昨日 summary（出複習題用）
       算今日配色
       輸出 context 包（goal / 主題 / 已教內容 / 第幾步 / 昨日重點 / 色碼）
  → claude -p（prompt_daily）→ 輸出 JSON：
       {
         "html": "信件內文（今日小步卡片 + 術語表 + 昨日複習區）",
         "topic_complete": true/false,
         "today_summary": "今天教了什麼（1~3 點，給明天複習）",
         "archive_markdown": "Notion 友善的 markdown 版"
       }
  → apply_result.py：驗證 JSON / html 非空；
       更新 progress.json（covered 追加、step++；若 topic_complete 則推進 current_index、重置 covered/step）
       寫 last_lesson.json = today_summary
       寫 lessons/YYYY-MM-DD-<slug>.md = archive_markdown
       把 html 輸出到 stdout
  → send_email.py 寄出
  → 成功才寫 daily marker
```

**關鍵原則（沿用新聞系統）**
- 進度**只有寄信成功才推進**，避免跳課。
- marker 確保每日只寄一次（exactly-once）；失敗不寫 marker，後續時段自動補跑。
- 失敗只記 `run.log`、不寄垃圾（輸出驗證過才寄）。
- 複習題在「今天」用昨日存的 summary 即時產生，因此只需保存一份精簡重點，不必預生題目。

## 6. 每週回顧（週日）

週 marker 未命中 → 從 `progress.json` 撈本週（依日期）教過的主題與 covered → `claude -p`（prompt_weekly）混出跨整週的回想測驗 → 送信 → 寫週 marker。每週流程**不推進主課進度**。日複習（間隔 1 天）+ 週複習（間隔 1 週）= 簡單但有效的間隔複習節奏。

## 7. 教學規則（寫進 prompt_daily.txt）

- 假設學習者幾乎不懂：**每個英文/技術術語第一次出現就定義**。
- **一封只教一個小概念**（單一 step），不要把整個主題倒完。
- 盡量用**生活比喻**帶抽象觀念。
- 程式碼採「跨天遞進」：例如 Day1 給「會出問題的寫法」、Day2 給「修好的寫法」。
- 信件結構：今日小步目標 → 解說（中英）→ 小段程式碼 → 「🥡 今日一句話帶走」→ 「📖 術語表」→ 明日預告 → 官方文件連結 → 「🔁 昨日複習」（題目在上、`—— 解答 ——` 在信末，不用 Gmail 不支援的 `<details>`）。
- 由 Claude 判斷 `topic_complete`：唯有該主題已合理走完數步才設 true。

## 8. 邊界與錯誤處理

- **課綱全部教完**：寄一封「你已完成全部課綱 🎉，可新增主題或開始循環複習」通知，停止推進度，不報錯。
- **claude 輸出非合法 JSON / html 為空**：視為失敗，記 `run.log`、不寄、不寫 marker，後續時段重試。
- **網路未就緒**：等待 + 逾時 + 重試（沿用新聞系統）。
- **headless 限制**：排程流程不依賴 Notion MCP（互動情境才用）。

## 9. config.env 新增

- `LEARN_GOAL`：學習目標字串（給 claude 產課綱與寫課）。預設：「已有基本程式/Groovy 經驗，想系統性學會用 Spring Boot 開發後端 REST API」。
- SMTP / 收件人沿用 `ai-news-digest` 設定；可選擇用獨立收件匣或標籤。

## 10. 測試（pytest，比照新聞 repo）

- 選下一個未走完主題 / step 的邏輯
- `topic_complete` 時的進度推進與 covered 重置
- marker 去重（每日 / 每週 exactly-once）
- claude JSON 解析與驗證（含去除 code fence、html 為空時拒寄）
- 課綱教完的處理
- 每週回顧的主題彙整（依日期取本週）
- 每日配色輪換

## 11. 明確不做（YAGNI / 日後）

- v1 **不做** grounding（抓官方原文墊底）；先用 Claude 知識 + 官方連結，品質不足再加。
- v1 **不做** Notion 自動同步；只產 markdown 存檔，手動觸發同步當獨立小工具。
- v1 **不做** Anki 卡產生（先驗證信內小測驗夠不夠用）。
- v1 **不做** 每月里程碑信（先日 + 週）。

## 12. spike 參考

`~/Workspace/java-learn-spike/`：`syllabus.draft.txt`、`lesson1b.html`、`lesson1b.png`（定案版調性樣本，主題拆小步 + 白話 + 術語表）。
