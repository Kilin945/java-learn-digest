# Java Learn Digest 📘

每天早上自動寄一封 5 分鐘可讀完的 Java / Spring Boot 學習信：依 `syllabus.txt` 課綱「一個主題拆成數小步、一天走一步」循序漸進，並用昨日複習做主動回想。沿用 macOS launchd 排程 → `claude -p` 依進度寫課 → Gmail SMTP 寄信。

## 運作
```
launchd 多時段觸發 → 已寄過？(marker) 秒跳過
  → build_lesson.py 依 progress.json 找出今日主題與第幾步、撈昨日重點
  → claude -p（prompt_daily）→ 回傳 JSON（html + 今日重點 + markdown 存檔）
  → apply_result.py 驗證 → send_email.py 寄出 → 成功才推進度、寫 lessons/<date>.md、打 marker
週日另寄「本週回顧」。
```

## 安裝
1. `cp config.env.example config.env`，填入 `GMAIL_USER`、`MAIL_TO`、`LEARN_GOAL`。
2. 把 Gmail App Password 存進 Keychain：
   `security add-generic-password -a "$GMAIL_USER" -s "java-learn-gmail" -w`
3. `./install.sh` 安裝排程。
4. 立即測試：`zsh run_learn.sh daily`

## 課綱
編輯 `syllabus.txt`（一行一主題，`#` 為註解/分章）。想跳過某主題就刪掉或註解該行。

## 把課歸檔到 Notion（半自動）
每天的課會存一份 markdown 在 `lessons/`。要歸檔時開 Claude Code 說「把 lessons/ 最近的課歸檔到 Notion」即可（互動情境下 Notion 才可用，排程流程不碰 Notion）。

## 檔案
| 檔案 | 作用 |
|------|------|
| `syllabus.txt` | 課綱 |
| `build_lesson.py` | 依進度組 claude 的輸入 |
| `apply_result.py` | 解析結果、寄成功才更新進度與存檔 |
| `send_email.py` | Gmail SMTP 寄信 |
| `run_learn.sh` | 主流程 |
| `prompt_daily.txt` / `prompt_weekly.txt` | claude 指令 |
| `state/` | 進度、歷史、marker |
| `lessons/` | 每課 markdown 存檔 |

## 測試
`python3 -m pytest -v`
