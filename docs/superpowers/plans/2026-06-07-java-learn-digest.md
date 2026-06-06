# java-learn-digest Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 每天寄一封 5 分鐘可讀完的 Java/Spring Boot 學習信，依 `syllabus.txt` 課綱「一個主題拆成數小步、一天走一步」循序漸進，並用昨日複習做主動回想；沿用 `ai-news-digest` 已驗證的送信與排程機制。

**Architecture:** 獨立新專案。純函式核心（`state_store.py`、`palette.py`）負責進度與配色邏輯並以 pytest 驗證；`build_lesson.py` 依進度組出餵給 `claude -p` 的 context；`apply_result.py` 解析 claude 回傳的 JSON、寄信成功後才更新進度與寫存檔；`run_learn.sh` 串接全流程並沿用新聞系統的 marker 去重／等網路／逾時重試／失敗不寄垃圾；`send_email.py` 由新聞系統的送信腳本照搬。

**Tech Stack:** Python 3（僅標準庫）、pytest（開發期）、zsh、macOS launchd、Gmail SMTP、Claude Code headless（`claude -p`）。

**工作目錄：** 所有路徑相對於 `/Users/yeqilin/Workspace/java-learn-digest/`（已 `git init`，已有 `.gitignore` 與 `docs/superpowers/specs/2026-06-07-java-learn-digest-design.md`）。

---

## 資料契約（跨任務共用，務必一致）

**`state/progress.json`**（目前進度指標）
```json
{"current_index": 0, "step": 1, "covered": [], "completed_topics": []}
```
- `current_index`：指向 `syllabus.txt` 主題清單的索引（0-based）。
- `step`：目前主題內的第幾小步（1-based）。
- `covered`：目前主題已教過的重點（字串清單）。
- `completed_topics`：`[{"topic": str, "finished": "YYYY-MM-DD", "steps": int}]`。

**`state/history.jsonl`**（每日一行，供昨日複習與每週回顧）
```json
{"date": "2026-06-07", "topic": "IoC 與依賴注入", "step": 1, "summary": "自己 new 會把類別和實作綁死：難換、難測"}
```

**claude 每日輸出（JSON，`apply_result.py` 解析）**
```json
{"html": "<div>…信件內文…</div>", "topic_complete": false, "today_summary": "今天教了什麼（給明天複習）", "archive_markdown": "## Day N …markdown…"}
```

**claude 每週輸出**：純 HTML 內文（與新聞系統相同，不是 JSON）。

---

## 檔案結構

| 檔案 | 責任 |
|------|------|
| `palette.py` | 每日卡片配色（10 色輪換）。純函式。 |
| `state_store.py` | 課綱讀取、進度讀寫與推進、歷史記錄。純函式為主。 |
| `build_lesson.py` | 依進度組出餵 claude 的 context（每日／每週兩種）。 |
| `apply_result.py` | 解析 claude JSON；`--commit` 時更新進度＋寫存檔。 |
| `send_email.py` | 由 `ai-news-digest/send_ai_news.py` 照搬、微調預設值。 |
| `run_learn.sh` | 主流程：去重→build→claude→驗證→送信→（成功才）commit＋marker。 |
| `prompt_daily.txt` / `prompt_weekly.txt` | claude 指令（含 beginner 規則與輸出格式）。 |
| `syllabus.txt` | 排序課綱。 |
| `config.env.example` | 設定範本。 |
| `requirements.txt` | 開發依賴（pytest）。 |
| `install.sh` + `launchd/*.plist.template` | 排程安裝（由新聞系統改寫）。 |
| `tests/` | pytest。 |
| `README.md` | 專案說明。 |

---

## Task 1: 專案骨架（課綱、設定範本、依賴）

**Files:**
- Create: `syllabus.txt`
- Create: `config.env.example`
- Create: `requirements.txt`

- [ ] **Step 1: 寫 `syllabus.txt`**（由 spike 草稿整理，移除暖身註解保留可選）

```
# java-learn-digest 課綱：目標 = 已有基本程式/Groovy 經驗，系統性學會用 Spring Boot 開發後端 REST API
# 一行一主題，# 為註解/分章。每天教「目前主題的下一小步」，主題走完才換下一行。
# 想跳過某主題，直接把那行刪掉或加 # 註解掉即可。

# ── M1 Spring 核心：容器與依賴注入 ──
IoC 與依賴注入：為什麼不要自己 new
Bean 是什麼：@Component / @Service / @Repository
建構子注入 vs 欄位注入 vs setter 注入
@Configuration 與 @Bean：手動定義 Bean
Bean 的 scope 與生命週期
@Autowired、@Qualifier 與多個候選 Bean 的解析
@Value 與 application.properties 讀設定
Profiles：dev / prod 用不同設定

# ── M2 Spring Boot：少寫設定就能跑 ──
@SpringBootApplication 與自動組態的原理
Starter 依賴：spring-boot-starter-web 幫你帶了什麼
application.yml 結構與設定優先序
內嵌 Tomcat 與 main() 啟動流程

# ── M3 Web 層：寫出 REST API ──
@RestController 與 @RequestMapping 家族
路徑參數、查詢參數、@RequestBody
DTO 與 entity 為什麼要分開
Bean Validation：@Valid 與 @NotNull
統一例外處理：@RestControllerAdvice

# ── M4 資料層：存進資料庫 ──
Spring Data JPA 與 Repository 介面
Entity 對應：@Entity / @Id / 關聯
衍生查詢 vs @Query
交易：@Transactional 的邊界與陷阱

# ── M5 測試 ──
單元測試 vs @SpringBootTest 整合測試
MockMvc 測 Controller
@DataJpaTest 等測試切片

# ── M6 上 production 前該懂的 ──
Actuator：健康檢查與指標
設定外部化與機密管理
Logging 與結構化日誌
Spring Security 入門：認證與授權概念
```

- [ ] **Step 2: 寫 `config.env.example`**

```bash
# 複製成 config.env（已被 .gitignore），填入你的設定。
# Gmail App Password 不放這裡，改存 macOS Keychain（見 README）。
GMAIL_USER="you@gmail.com"
MAIL_TO="you@gmail.com"
KEYCHAIN_SERVICE="java-learn-gmail"

# 學習目標：給 claude 產課與決定深度用
LEARN_GOAL="已有基本程式/Groovy 經驗，想系統性學會用 Spring Boot 開發後端 REST API"

# 執行環境（可選，預設見 run_learn.sh）
# CLAUDE_BIN="$HOME/.local/bin/claude"
# PYTHON_BIN="/opt/homebrew/bin/python3"
# CLAUDE_MODEL="sonnet"
```

- [ ] **Step 3: 寫 `requirements.txt`**

```
pytest
```

- [ ] **Step 4: Commit**

```bash
git add syllabus.txt config.env.example requirements.txt
git commit -m "新增課綱、設定範本與開發依賴"
```

---

## Task 2: 每日配色 `palette.py`

**Files:**
- Create: `palette.py`
- Test: `tests/test_palette.py`

- [ ] **Step 1: 寫失敗測試**

```python
# tests/test_palette.py
from palette import daily_color, PALETTE

def test_palette_has_ten_colors():
    assert len(PALETTE) == 10
    for bg, bar, txt in PALETTE:
        assert bg.startswith("#") and bar.startswith("#") and txt.startswith("#")

def test_daily_color_rotates_by_day_of_year():
    # 第 158 天（2026-06-07）→ 158 % 10 = 8
    assert daily_color(158) == PALETTE[8]
    assert daily_color(1) == PALETTE[1]
    assert daily_color(10) == PALETTE[0]
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd /Users/yeqilin/Workspace/java-learn-digest && python3 -m pytest tests/test_palette.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'palette'`

- [ ] **Step 3: 寫 `palette.py`**

```python
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""每日卡片配色：10 色輪換，每天 +1。"""

# (BG=底色, BAR=左側色條與重點色, TXT=徽章文字色)
PALETTE = [
    ("#eef4ff", "#5b8def", "#3b6cf6"),
    ("#ecf7ef", "#4caf72", "#1e9e57"),
    ("#f1ecfb", "#8a6bd8", "#6b3bf6"),
    ("#e8f6f5", "#2bb0a6", "#0f9b9b"),
    ("#fbf3e3", "#d99b3f", "#b9791f"),
    ("#fdeef0", "#e0738a", "#d83a5e"),
    ("#edeefb", "#6b72d6", "#5159c9"),
    ("#e8f4fb", "#3f97c9", "#2b7fb0"),
    ("#f2f6e8", "#88a83f", "#6e8c28"),
    ("#f9edf6", "#c56bb0", "#b04b9b"),
]


def daily_color(day_of_year):
    """依一年中的第幾天回傳 (bg, bar, txt)。"""
    return PALETTE[day_of_year % len(PALETTE)]
```

- [ ] **Step 4: 跑測試確認通過**

Run: `python3 -m pytest tests/test_palette.py -v`
Expected: PASS（3 passed）

- [ ] **Step 5: Commit**

```bash
git add palette.py tests/test_palette.py
git commit -m "加入每日卡片配色輪換"
```

---

## Task 3: 課綱與進度讀取 `state_store.py`（第一部分）

**Files:**
- Create: `state_store.py`
- Test: `tests/test_state_store.py`

- [ ] **Step 1: 寫失敗測試**

```python
# tests/test_state_store.py
import json
import state_store as ss

def test_load_syllabus_skips_comments_and_blanks(tmp_path):
    p = tmp_path / "syllabus.txt"
    p.write_text("# 章節\n\n主題一\n  主題二  \n# 註解\n主題三\n", encoding="utf-8")
    assert ss.load_syllabus(str(p)) == ["主題一", "主題二", "主題三"]

def test_load_progress_returns_defaults_when_missing(tmp_path):
    prog = ss.load_progress(str(tmp_path / "nope.json"))
    assert prog == {"current_index": 0, "step": 1, "covered": [], "completed_topics": []}

def test_load_progress_returns_defaults_on_corrupt_file(tmp_path):
    p = tmp_path / "progress.json"
    p.write_text("{ not json", encoding="utf-8")
    assert ss.load_progress(str(p))["current_index"] == 0

def test_save_then_load_progress_roundtrip(tmp_path):
    p = str(tmp_path / "state" / "progress.json")  # 巢狀目錄須自動建立
    prog = {"current_index": 2, "step": 3, "covered": ["a"], "completed_topics": []}
    ss.save_progress(p, prog)
    assert ss.load_progress(p) == prog

def test_current_topic_returns_topic_or_none_when_finished(tmp_path):
    syllabus = ["A", "B"]
    assert ss.current_topic(syllabus, {"current_index": 0}) == "A"
    assert ss.current_topic(syllabus, {"current_index": 1}) == "B"
    assert ss.current_topic(syllabus, {"current_index": 2}) is None
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `python3 -m pytest tests/test_state_store.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'state_store'`

- [ ] **Step 3: 寫 `state_store.py`（第一部分）**

```python
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""課綱讀取、進度讀寫與推進、每日歷史記錄。純函式為主，方便測試。"""
import os
import sys
import json
import copy
from datetime import date, timedelta

DEFAULT_PROGRESS = {"current_index": 0, "step": 1, "covered": [], "completed_topics": []}


def load_syllabus(path):
    """讀 syllabus.txt：每行一主題，# 開頭與空行略過，前後空白去掉。"""
    topics = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            topics.append(line)
    return topics


def load_progress(path):
    """讀 progress.json；不存在或壞掉都回傳預設值（深拷貝）。"""
    if os.path.exists(path):
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
            # 補齊缺漏鍵，避免舊檔造成 KeyError
            merged = copy.deepcopy(DEFAULT_PROGRESS)
            merged.update({k: data[k] for k in DEFAULT_PROGRESS if k in data})
            return merged
        except (json.JSONDecodeError, ValueError, OSError) as e:
            print(f"WARN: 讀取 {path} 失敗（用預設值）：{e!r}", file=sys.stderr)
    return copy.deepcopy(DEFAULT_PROGRESS)


def save_progress(path, progress):
    """寫 progress.json，自動建立巢狀目錄。"""
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(progress, f, ensure_ascii=False, indent=2)


def current_topic(syllabus, progress):
    """回傳目前主題字串；課綱已全部走完則回傳 None。"""
    idx = progress.get("current_index", 0)
    return syllabus[idx] if 0 <= idx < len(syllabus) else None
```

- [ ] **Step 4: 跑測試確認通過**

Run: `python3 -m pytest tests/test_state_store.py -v`
Expected: PASS（5 passed）

- [ ] **Step 5: Commit**

```bash
git add state_store.py tests/test_state_store.py
git commit -m "加入課綱與進度的讀取與儲存"
```

---

## Task 4: 進度推進與歷史 `state_store.py`（第二部分）

**Files:**
- Modify: `state_store.py`（接續 Task 3 的檔尾新增函式）
- Test: `tests/test_state_store.py`（新增測試）

- [ ] **Step 1: 新增失敗測試**

```python
# 接在 tests/test_state_store.py 檔尾
def test_advance_increments_step_when_topic_not_complete():
    prog = {"current_index": 0, "step": 1, "covered": [], "completed_topics": []}
    new = ss.advance_progress(prog, "IoC", "Day1 重點", topic_complete=False, today="2026-06-07")
    assert new["step"] == 2
    assert new["current_index"] == 0
    assert new["covered"] == ["Day1 重點"]
    assert new["completed_topics"] == []
    # 不可改到原物件
    assert prog["step"] == 1

def test_advance_moves_to_next_topic_when_complete():
    prog = {"current_index": 0, "step": 3, "covered": ["a", "b"], "completed_topics": []}
    new = ss.advance_progress(prog, "IoC", "收尾重點", topic_complete=True, today="2026-06-07")
    assert new["current_index"] == 1
    assert new["step"] == 1
    assert new["covered"] == []
    assert new["completed_topics"] == [{"topic": "IoC", "finished": "2026-06-07", "steps": 3}]

def test_history_append_and_load_roundtrip(tmp_path):
    p = str(tmp_path / "state" / "history.jsonl")
    ss.append_history(p, {"date": "2026-06-07", "topic": "IoC", "step": 1, "summary": "s1"})
    ss.append_history(p, {"date": "2026-06-08", "topic": "IoC", "step": 2, "summary": "s2"})
    rows = ss.load_history(p)
    assert [r["summary"] for r in rows] == ["s1", "s2"]

def test_load_history_missing_returns_empty(tmp_path):
    assert ss.load_history(str(tmp_path / "none.jsonl")) == []

def test_last_summary_returns_latest_or_none():
    assert ss.last_summary([]) is None
    assert ss.last_summary([{"summary": "a"}, {"summary": "b"}]) == "b"

def test_recent_history_filters_by_window():
    # 視窗 = (today - days, today]，即 days=7、today=2026-06-07 時保留日期 > 2026-05-31
    hist = [
        {"date": "2026-05-30", "summary": "too_old"},   # 早於邊界 → 排除
        {"date": "2026-06-01", "summary": "old"},        # 在窗內 → 保留
        {"date": "2026-06-05", "summary": "mid"},
        {"date": "2026-06-07", "summary": "new"},        # 含今天 → 保留
    ]
    got = ss.recent_history(hist, today="2026-06-07", days=7)
    assert [r["summary"] for r in got] == ["old", "mid", "new"]
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `python3 -m pytest tests/test_state_store.py -v`
Expected: FAIL — `AttributeError: module 'state_store' has no attribute 'advance_progress'`

- [ ] **Step 3: 在 `state_store.py` 檔尾新增實作**

```python
def advance_progress(progress, topic, today_summary, topic_complete, today):
    """回傳推進後的新進度（不改原物件）。
    topic：目前主題字串；today：'YYYY-MM-DD'。
    未完成→step+1、把今日重點併入 covered；完成→收進 completed_topics、換下一主題。"""
    new = copy.deepcopy(progress)
    new.setdefault("covered", []).append(today_summary)
    if topic_complete:
        new.setdefault("completed_topics", []).append(
            {"topic": topic, "finished": today, "steps": new.get("step", 1)}
        )
        new["current_index"] = new.get("current_index", 0) + 1
        new["step"] = 1
        new["covered"] = []
    else:
        new["step"] = new.get("step", 1) + 1
    return new


def append_history(path, entry):
    """把一筆每日記錄附加到 history.jsonl（一行一筆 JSON）。"""
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")


def load_history(path):
    """讀 history.jsonl 成 list[dict]；不存在回傳空清單。"""
    if not os.path.exists(path):
        return []
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def last_summary(history):
    """回傳最後一筆的 summary；空則 None。"""
    return history[-1]["summary"] if history else None


def recent_history(history, today, days=7):
    """回傳日期在 (today - days, today] 之間的記錄。today 為 'YYYY-MM-DD'。"""
    today_d = date.fromisoformat(today)
    cutoff = today_d - timedelta(days=days)
    out = []
    for r in history:
        try:
            d = date.fromisoformat(r["date"])
        except (KeyError, ValueError):
            continue
        if cutoff < d <= today_d:
            out.append(r)
    return out
```

- [ ] **Step 4: 跑測試確認通過**

Run: `python3 -m pytest tests/test_state_store.py -v`
Expected: PASS（全部 passed）

- [ ] **Step 5: Commit**

```bash
git add state_store.py tests/test_state_store.py
git commit -m "加入進度推進與每日學習歷史記錄"
```

---

## Task 5: 組 context `build_lesson.py`

**Files:**
- Create: `build_lesson.py`
- Test: `tests/test_build_lesson.py`

- [ ] **Step 1: 寫失敗測試**

```python
# tests/test_build_lesson.py
import build_lesson as bl

def test_daily_context_contains_topic_step_and_colors():
    ctx = bl.format_daily_context(
        goal="學 Spring Boot",
        topic="IoC 與依賴注入：為什麼不要自己 new",
        step=2,
        covered=["Day1：自己 new 會綁死"],
        yesterday="自己 new 會綁死：難換難測",
        color=("#f2f6e8", "#88a83f", "#6e8c28"),
        today="2026-06-07",
    )
    assert "GOAL: 學 Spring Boot" in ctx
    assert "TOPIC: IoC 與依賴注入" in ctx
    assert "STEP: 2" in ctx
    assert "- Day1：自己 new 會綁死" in ctx
    assert "YESTERDAY_SUMMARY: 自己 new 會綁死：難換難測" in ctx
    assert "COLOR_BG: #f2f6e8" in ctx
    assert "COLOR_BAR: #88a83f" in ctx
    assert "DATE: 2026-06-07" in ctx

def test_daily_context_marks_no_yesterday_for_first_lesson():
    ctx = bl.format_daily_context(
        goal="g", topic="t", step=1, covered=[], yesterday=None,
        color=("#a", "#b", "#c"), today="2026-06-07",
    )
    assert "YESTERDAY_SUMMARY: （無，這是第一課）" in ctx

def test_finished_sentinel():
    assert bl.format_finished() == "STATUS: FINISHED"

def test_weekly_context_lists_week_rows():
    rows = [
        {"date": "2026-06-02", "topic": "IoC", "step": 1, "summary": "s1"},
        {"date": "2026-06-03", "topic": "IoC", "step": 2, "summary": "s2"},
    ]
    ctx = bl.format_weekly_context(goal="g", rows=rows,
                                   color=("#a", "#b", "#c"), today="2026-06-07")
    assert "THIS_WEEK:" in ctx
    assert "2026-06-02 [IoC #1] s1" in ctx
    assert "2026-06-03 [IoC #2] s2" in ctx
    assert "DATE: 2026-06-07" in ctx
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `python3 -m pytest tests/test_build_lesson.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'build_lesson'`

- [ ] **Step 3: 寫 `build_lesson.py`**

```python
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""依進度組出餵給 claude 的 context 文字。
用法：
  build_lesson.py daily  --syllabus … --progress … --history …
  build_lesson.py weekly --history … --progress …
每日：找出目前主題與第幾步、昨日重點、今日配色，印出 context；課綱走完則印 STATUS: FINISHED。
每週：印出本週（7 天內）教過的條目。
goal 取自環境變數 LEARN_GOAL。配色取自一年中的第幾天。
"""
import os
import sys
import argparse
from datetime import date

import state_store as ss
from palette import daily_color

DEFAULT_GOAL = "已有基本程式/Groovy 經驗，想系統性學會用 Spring Boot 開發後端 REST API"


def format_daily_context(goal, topic, step, covered, yesterday, color, today):
    bg, bar, txt = color
    covered_block = "\n".join(f"- {c}" for c in covered) if covered else "（尚無，這是這個主題的第一步）"
    yest = yesterday if yesterday else "（無，這是第一課）"
    return (
        f"GOAL: {goal}\n"
        f"DATE: {today}\n"
        f"TOPIC: {topic}\n"
        f"STEP: {step}\n"
        f"COVERED_SO_FAR:\n{covered_block}\n"
        f"YESTERDAY_SUMMARY: {yest}\n"
        f"COLOR_BG: {bg}\n"
        f"COLOR_BAR: {bar}\n"
        f"COLOR_TXT: {txt}"
    )


def format_finished():
    return "STATUS: FINISHED"


def format_weekly_context(goal, rows, color, today):
    bg, bar, txt = color
    if rows:
        lines = "\n".join(f"{r['date']} [{r['topic']} #{r['step']}] {r['summary']}" for r in rows)
    else:
        lines = "（本週尚無紀錄）"
    return (
        f"GOAL: {goal}\n"
        f"DATE: {today}\n"
        f"THIS_WEEK:\n{lines}\n"
        f"COLOR_BG: {bg}\n"
        f"COLOR_BAR: {bar}\n"
        f"COLOR_TXT: {txt}"
    )


def main(argv=None):
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["daily", "weekly"])
    ap.add_argument("--syllabus", default=os.path.join(here, "syllabus.txt"))
    ap.add_argument("--progress", default=os.path.join(here, "state", "progress.json"))
    ap.add_argument("--history", default=os.path.join(here, "state", "history.jsonl"))
    args = ap.parse_args(argv)

    goal = os.environ.get("LEARN_GOAL") or DEFAULT_GOAL
    today = date.today()
    today_s = today.isoformat()
    color = daily_color(today.timetuple().tm_yday)

    if args.mode == "daily":
        syllabus = ss.load_syllabus(args.syllabus)
        progress = ss.load_progress(args.progress)
        topic = ss.current_topic(syllabus, progress)
        if topic is None:
            print(format_finished())
            return
        history = ss.load_history(args.history)
        print(format_daily_context(
            goal=goal, topic=topic, step=progress.get("step", 1),
            covered=progress.get("covered", []),
            yesterday=ss.last_summary(history),
            color=color, today=today_s,
        ))
    else:
        history = ss.load_history(args.history)
        rows = ss.recent_history(history, today_s, days=7)
        print(format_weekly_context(goal=goal, rows=rows, color=color, today=today_s))


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: 跑測試確認通過**

Run: `python3 -m pytest tests/test_build_lesson.py -v`
Expected: PASS（4 passed）

- [ ] **Step 5: Commit**

```bash
git add build_lesson.py tests/test_build_lesson.py
git commit -m "加入依進度組出每日與每週課程內容的程式"
```

---

## Task 6: 解析與套用 claude 結果 `apply_result.py`

**Files:**
- Create: `apply_result.py`
- Test: `tests/test_apply_result.py`

- [ ] **Step 1: 寫失敗測試**

```python
# tests/test_apply_result.py
import json
import pytest
import apply_result as ar

VALID = {
    "html": "<div>hi</div>",
    "topic_complete": False,
    "today_summary": "今天教了 X",
    "archive_markdown": "## Day 1\n內容",
}

def test_parse_plain_json():
    assert ar.parse_result(json.dumps(VALID))["html"] == "<div>hi</div>"

def test_parse_strips_code_fence():
    text = "```json\n" + json.dumps(VALID) + "\n```"
    assert ar.parse_result(text)["today_summary"] == "今天教了 X"

def test_parse_rejects_empty_html():
    bad = dict(VALID, html="   ")
    with pytest.raises(ValueError):
        ar.parse_result(json.dumps(bad))

def test_parse_rejects_missing_key():
    bad = {"html": "<div>x</div>"}
    with pytest.raises(ValueError):
        ar.parse_result(json.dumps(bad))

def test_parse_rejects_non_json():
    with pytest.raises(ValueError):
        ar.parse_result("這不是 JSON")

def test_commit_writes_archive_and_advances_state(tmp_path):
    syl = tmp_path / "syllabus.txt"
    syl.write_text("主題甲\n主題乙\n", encoding="utf-8")
    prog = str(tmp_path / "state" / "progress.json")
    hist = str(tmp_path / "state" / "history.jsonl")
    lessons = str(tmp_path / "lessons")
    res = dict(VALID, topic_complete=True, today_summary="收尾")
    ar.commit(res, syllabus_path=str(syl), progress_path=prog,
              history_path=hist, lessons_dir=lessons, today="2026-06-07")
    import state_store as ss
    p = ss.load_progress(prog)
    assert p["current_index"] == 1          # 主題完成→換下一個
    rows = ss.load_history(hist)
    assert rows[-1] == {"date": "2026-06-07", "topic": "主題甲", "step": 1, "summary": "收尾"}
    md = (tmp_path / "lessons" / "2026-06-07.md").read_text(encoding="utf-8")
    assert md == "## Day 1\n內容"
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `python3 -m pytest tests/test_apply_result.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'apply_result'`

- [ ] **Step 3: 寫 `apply_result.py`**

```python
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""解析 claude 每日輸出的 JSON。
從 stdin 讀文字：
  預設（驗證模式）：解析＋驗證後，把 html 印到 stdout（不動任何狀態）。
  --commit：另外更新 progress、append history、寫 lessons/<date>.md。
驗證或解析失敗 → 印錯誤到 stderr 並以非 0 結束（讓 run_learn.sh 視為失敗、不寄、待補跑）。
"""
import os
import sys
import json
import argparse
from datetime import date

import state_store as ss

REQUIRED = ("html", "topic_complete", "today_summary", "archive_markdown")


def parse_result(text):
    """把 claude 輸出解析成 dict 並驗證；失敗丟 ValueError。"""
    s = text.strip()
    if s.startswith("```"):
        lines = s.splitlines()
        if lines and lines[0].startswith("```"):
            lines = lines[1:]
        if lines and lines[-1].strip().startswith("```"):
            lines = lines[:-1]
        s = "\n".join(lines).strip()
    try:
        data = json.loads(s)
    except (json.JSONDecodeError, ValueError) as e:
        raise ValueError(f"輸出不是合法 JSON：{e}")
    if not isinstance(data, dict):
        raise ValueError("輸出 JSON 不是物件")
    for k in REQUIRED:
        if k not in data:
            raise ValueError(f"缺少必要欄位：{k}")
    if not isinstance(data["html"], str) or not data["html"].strip():
        raise ValueError("html 為空")
    if not isinstance(data["topic_complete"], bool):
        raise ValueError("topic_complete 必須是布林")
    return data


def commit(res, syllabus_path, progress_path, history_path, lessons_dir, today):
    """寄信成功後呼叫：寫存檔、推進度、記歷史。"""
    syllabus = ss.load_syllabus(syllabus_path)
    progress = ss.load_progress(progress_path)
    topic = ss.current_topic(syllabus, progress) or "（課綱外）"
    step = progress.get("step", 1)

    os.makedirs(lessons_dir, exist_ok=True)
    with open(os.path.join(lessons_dir, f"{today}.md"), "w", encoding="utf-8") as f:
        f.write(res["archive_markdown"])

    ss.append_history(history_path,
                      {"date": today, "topic": topic, "step": step,
                       "summary": res["today_summary"]})
    new_prog = ss.advance_progress(progress, topic, res["today_summary"],
                                   res["topic_complete"], today)
    ss.save_progress(progress_path, new_prog)


def main(argv=None):
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    ap.add_argument("--commit", action="store_true")
    ap.add_argument("--syllabus", default=os.path.join(here, "syllabus.txt"))
    ap.add_argument("--progress", default=os.path.join(here, "state", "progress.json"))
    ap.add_argument("--history", default=os.path.join(here, "state", "history.jsonl"))
    ap.add_argument("--lessons-dir", default=os.path.join(here, "lessons"))
    args = ap.parse_args(argv)

    try:
        res = parse_result(sys.stdin.read())
    except ValueError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(2)

    if args.commit:
        commit(res, args.syllabus, args.progress, args.history,
               args.lessons_dir, date.today().isoformat())
        print("OK: 已更新進度與存檔", file=sys.stderr)
    else:
        sys.stdout.write(res["html"])


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: 跑測試確認通過**

Run: `python3 -m pytest tests/test_apply_result.py -v`
Expected: PASS（6 passed）

- [ ] **Step 5: Commit**

```bash
git add apply_result.py tests/test_apply_result.py
git commit -m "加入解析與套用每日課程結果（寄信成功才更新進度）"
```

---

## Task 7: 送信腳本 `send_email.py`

**Files:**
- Create: `send_email.py`（由 `ai-news-digest/send_ai_news.py` 照搬，改預設主旨與寄件人名稱、Keychain 預設服務名）
- Test: `tests/test_send_email.py`

- [ ] **Step 1: 寫失敗測試（只測設定解析，不真的寄信）**

```python
# tests/test_send_email.py
import send_email as se

def test_load_config_reads_file_and_env(tmp_path, monkeypatch):
    cfg = tmp_path / "config.env"
    cfg.write_text('GMAIL_USER="a@gmail.com"\nKEYCHAIN_SERVICE="java-learn-gmail"\n', encoding="utf-8")
    monkeypatch.setattr(se, "_CONFIG_PATH", str(cfg))
    monkeypatch.delenv("GMAIL_USER", raising=False)
    monkeypatch.delenv("MAIL_TO", raising=False)
    conf = se.load_config()
    assert conf["GMAIL_USER"] == "a@gmail.com"
    assert conf["MAIL_TO"] == "a@gmail.com"          # 未設 MAIL_TO → 回退成寄給自己
    assert conf["KEYCHAIN_SERVICE"] == "java-learn-gmail"

def test_env_overrides_file(tmp_path, monkeypatch):
    cfg = tmp_path / "config.env"
    cfg.write_text('GMAIL_USER="file@gmail.com"\n', encoding="utf-8")
    monkeypatch.setattr(se, "_CONFIG_PATH", str(cfg))
    monkeypatch.setenv("GMAIL_USER", "env@gmail.com")
    assert se.load_config()["GMAIL_USER"] == "env@gmail.com"
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `python3 -m pytest tests/test_send_email.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'send_email'`

- [ ] **Step 3: 寫 `send_email.py`**（與新聞版同邏輯，差別：`_CONFIG_PATH` 可測、預設主旨/寄件人為學習信、Keychain 預設 `java-learn-gmail`）

```python
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""學習信寄送：從 stdin 讀 HTML，透過 Gmail SMTP (STARTTLS) 寄出。
設定優先序：環境變數 > 同目錄 config.env。App Password 從 macOS Keychain 讀。
用法：echo "<html>" | python3 send_email.py ["主旨前綴"]
"""
import os
import sys
import ssl
import smtplib
import datetime
import subprocess
from email.mime.text import MIMEText
from email.utils import formataddr

SMTP_HOST = "smtp.gmail.com"
SMTP_PORT = 587
_CONFIG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.env")


def load_config():
    cfg = {}
    if os.path.exists(_CONFIG_PATH):
        with open(_CONFIG_PATH, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                cfg[k.strip()] = os.path.expandvars(v.strip().strip('"').strip("'"))

    def get(key, default=None):
        return os.environ.get(key) or cfg.get(key) or default

    return {
        "GMAIL_USER": get("GMAIL_USER"),
        "MAIL_TO": get("MAIL_TO") or get("GMAIL_USER"),
        "KEYCHAIN_SERVICE": get("KEYCHAIN_SERVICE", "java-learn-gmail"),
    }


def get_app_password(gmail_user, service):
    try:
        out = subprocess.run(
            ["security", "find-generic-password", "-a", gmail_user, "-s", service, "-w"],
            check=True, capture_output=True, text=True,
        )
        return out.stdout.strip()
    except subprocess.CalledProcessError as e:
        print(f"ERROR: 無法從 Keychain 讀取密碼: {e.stderr.strip()}", file=sys.stderr)
        sys.exit(3)


def main():
    conf = load_config()
    if not conf["GMAIL_USER"]:
        print("ERROR: 未設定 GMAIL_USER（請建立 config.env，參考 config.env.example）", file=sys.stderr)
        sys.exit(4)

    html_body = sys.stdin.read()
    stripped = html_body.strip()
    if stripped.startswith("```"):
        lines = stripped.splitlines()
        if lines and lines[0].startswith("```"):
            lines = lines[1:]
        if lines and lines[-1].strip().startswith("```"):
            lines = lines[:-1]
        html_body = "\n".join(lines)

    if not html_body.strip():
        print("ERROR: 收到空的內文，停止寄送。", file=sys.stderr)
        sys.exit(2)

    today = datetime.date.today().strftime("%Y-%m-%d")
    subject_prefix = sys.argv[1] if len(sys.argv) > 1 else "每日 Java/Spring Boot"
    subject = f"{subject_prefix} — {today}"

    app_password = get_app_password(conf["GMAIL_USER"], conf["KEYCHAIN_SERVICE"])

    msg = MIMEText(html_body, "html", "utf-8")
    msg["Subject"] = subject
    msg["From"] = formataddr(("Java Learn Digest", conf["GMAIL_USER"]))
    msg["To"] = conf["MAIL_TO"]

    try:
        ctx = ssl.create_default_context()
        with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=60) as s:
            s.starttls(context=ctx)
            s.login(conf["GMAIL_USER"], app_password)
            s.send_message(msg)
        print(f"OK: 寄送成功 -> {conf['MAIL_TO']}（主旨：{subject}）")
    except Exception as e:
        print(f"ERROR: 寄送失敗: {e!r}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: 跑測試確認通過**

Run: `python3 -m pytest tests/test_send_email.py -v`
Expected: PASS（2 passed）

- [ ] **Step 5: Commit**

```bash
git add send_email.py tests/test_send_email.py
git commit -m "加入學習信的寄送腳本"
```

---

## Task 8: claude 指令 `prompt_daily.txt` / `prompt_weekly.txt`

**Files:**
- Create: `prompt_daily.txt`
- Create: `prompt_weekly.txt`

- [ ] **Step 1: 寫 `prompt_daily.txt`**

```
你是一位耐心的 Java / Spring Boot 家教，學生幾乎是初學者。本提示最後會附上一份「今日課程資料」（含 GOAL 學習目標、TOPIC 今天的主題、STEP 第幾小步、COVERED_SO_FAR 這個主題已教過的重點、YESTERDAY_SUMMARY 昨天教的重點、COLOR_BG/BAR/TXT 今日配色、DATE 日期）。

你的任務：只教「這個主題的下一小步」，並出昨日複習題。請「只輸出一個 JSON 物件」，不要任何前言、解說或 markdown 圍欄。

【教學原則】
- 把學生當完全不會的人：每個英文/技術術語第一次出現就用中文定義。
- 一封信只教一個小概念（對應 STEP），不要把整個主題倒完。COVERED_SO_FAR 是已教過的，不要重複，請接著往下教。
- 多用生活化比喻帶抽象觀念。
- 程式碼跨天遞進：例如「問題寫法」→ 隔天「修好寫法」。程式碼精簡、可讀。
- 英文為主、中文輔助：概念標題用英文，解說用中文。
- 篇幅以 5 分鐘讀完為準。
- 若 COVERED_SO_FAR 顯示主題已大致講完，這一步做收尾總結，並把 topic_complete 設為 true；否則 false。

【輸出 JSON 格式】
{
  "html": "<信件 HTML 內文，見下方版型>",
  "topic_complete": true 或 false,
  "today_summary": "用一句話總結今天教的重點（給明天出複習題用）",
  "archive_markdown": "把今天這課寫成乾淨的 markdown（標題用 ## TOPIC · 第 STEP 步，含概念、程式碼區塊、術語表），供日後歸檔筆記"
}

【html 版型】（把 BG/BAR/TXT 換成 COLOR_*；DATE/TOPIC/STEP 帶入；最外層不需要 <html>/<head>）
<div style="font-family:-apple-system,'PingFang TC','Helvetica Neue',Arial,sans-serif;max-width:680px;margin:0 auto;color:#16213e;">
  <div style="font-size:20px;font-weight:800;color:#1a2b4a;border-left:5px solid BAR;padding-left:12px;margin:0 0 6px;">📘 每日 Java / Spring Boot · DATE</div>
  <div style="font-size:12.5px;color:#8a909c;padding-left:13px;margin:0 0 18px;">主題「TOPIC」· 第 STEP 步 · 今天搞懂一件事就好</div>

  <div style="background:BG;border-left:5px solid BAR;border-radius:10px;padding:16px 18px;margin-bottom:14px;">
    <div style="font-size:11px;font-weight:700;color:TXT;letter-spacing:.5px;text-transform:uppercase;margin-bottom:4px;">Today's tiny step · 今日小步</div>
    <div style="font-size:18px;font-weight:800;color:#16213e;line-height:1.35;">英文概念標題</div>
    <div style="font-size:12.5px;color:#7a818d;margin:4px 0 12px;">一句中文點出今天要懂的事</div>
    <div style="font-size:13.5px;color:#2c3340;line-height:1.7;">中文解說（用比喻，定義術語）</div>
    <!-- 視需要放一段深色程式碼區塊 -->
    <div style="background:#1f2430;border-radius:8px;padding:12px 14px;margin:12px 0;overflow-x:auto;"><pre style="margin:0;font-family:'SF Mono',Menlo,Consolas,monospace;font-size:12.5px;line-height:1.6;color:#e6e6e6;">程式碼</pre></div>
    <div style="font-size:12.5px;color:#3b424f;line-height:1.6;background:#fff;border-radius:8px;padding:10px 12px;margin-top:12px;"><b style="color:TXT;">🥡 今日一句話帶走：</b>濃縮重點。</div>
    <div style="font-size:12px;margin-top:10px;"><b style="color:#3b424f;">深入官方文件</b> · <a href="官方連結" style="color:#3b6cf6;text-decoration:none;">標題</a></div>
  </div>

  <div style="background:#fbfcf8;border:1px solid #e2e6da;border-radius:10px;padding:13px 16px;margin-bottom:14px;">
    <div style="font-size:13px;font-weight:800;color:TXT;margin-bottom:8px;">📖 今日術語表</div>
    <table style="width:100%;border-collapse:collapse;font-size:12.5px;color:#3b424f;line-height:1.55;">
      <tr><td style="padding:4px 8px 4px 0;white-space:nowrap;vertical-align:top;"><b>術語</b><br><span style="color:#8a909c;">中文</span></td><td style="padding:4px 0;">白話定義。</td></tr>
    </table>
  </div>

  <!-- 昨日複習：若 YESTERDAY_SUMMARY 為「（無，這是第一課）」則整段省略 -->
  <div style="background:#f7f8f5;border:1px dashed #c3cdb0;border-radius:10px;padding:14px 16px;margin-bottom:14px;">
    <div style="font-size:13px;font-weight:800;color:TXT;margin-bottom:4px;">🔁 昨日複習 · 主動回想<span style="font-weight:600;color:#9aa1ad;font-size:11px;margin-left:6px;">（先別看解答，自己想想看）</span></div>
    <ol style="margin:8px 0 0;padding-left:20px;font-size:13px;color:#2c3340;line-height:1.7;">
      <li>依 YESTERDAY_SUMMARY 出 2~3 題回想題</li>
    </ol>
    <div style="border-top:1px solid #e2e6da;margin-top:12px;padding-top:8px;font-size:12px;color:#7a818d;line-height:1.65;"><b style="color:#9aa1ad;">—— 解答 ——</b><br>逐題簡短解答。</div>
  </div>

  <div style="text-align:center;font-size:11.5px;color:#9aa1ad;padding-top:6px;">由 Java Learn Digest 依你的 syllabus 進度自動產生 · 每天 5 分鐘 · 進步一點點</div>
</div>

再次強調：只輸出一個 JSON 物件，html 欄位的值是上面那段 HTML 字串。
```

- [ ] **Step 2: 寫 `prompt_weekly.txt`**

```
你是一位 Java / Spring Boot 家教。本提示最後附上「本週課程資料」（GOAL、DATE、THIS_WEEK 本週各天教過的條目、COLOR_*）。

任務：做一封「本週回顧」信，幫學生把這週學的東西用主動回想串起來。請「只輸出 HTML 內文」（從 <div> 開始，不要 JSON、不要 markdown 圍欄、不要前言）。

要求：
- 開頭一行標題列：📘 每週回顧 · Java / Spring Boot · DATE（用 COLOR_BAR 當左邊色條）。
- 依 THIS_WEEK 的主題，出 5~8 題跨整週的回想題（混不同主題、由淺入深），題目在上。
- 信末放「—— 解答 ——」區塊逐題簡短解答（不要用 <details>，Gmail 不支援）。
- 英文術語沿用、必要時附一句中文。
- 整體沿用柔和卡片風格、最大寬度 680px、字級與每日信一致。
- 若 THIS_WEEK 是「（本週尚無紀錄）」，就出一封簡短鼓勵信，提醒明天開始的第一課。
```

- [ ] **Step 3: Commit**

```bash
git add prompt_daily.txt prompt_weekly.txt
git commit -m "加入每日與每週課程的指令範本"
```

---

## Task 9: 主流程 `run_learn.sh`

**Files:**
- Create: `run_learn.sh`（由 `ai-news-digest/run_ai_news.sh` 改寫）

- [ ] **Step 1: 寫 `run_learn.sh`**

```bash
#!/bin/zsh
# 學習信寄送：由 launchd 觸發，可共用每日/每週。
# 用法：run_learn.sh [kind] [prompt檔] [主旨前綴]
#   kind = daily(預設) | weekly
# 可靠性：每週期只成功寄一次（state/ 下的 marker 去重）；失敗只記 log、不寄垃圾、待補跑。

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$DIR/run.log"
STATE_DIR="$DIR/state"
mkdir -p "$STATE_DIR"

if [ ! -f "$DIR/config.env" ]; then
  echo "ERROR: 找不到 $DIR/config.env，請先 cp config.env.example config.env 並填入設定。" >> "$LOG"
  exit 5
fi
source "$DIR/config.env"
export GMAIL_USER MAIL_TO KEYCHAIN_SERVICE LEARN_GOAL

CLAUDE="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
PYTHON="${PYTHON_BIN:-/opt/homebrew/bin/python3}"
MODEL="${CLAUDE_MODEL:-sonnet}"

KIND="${1:-daily}"
if [ "$KIND" = "weekly" ]; then
  PROMPT_FILE="${2:-prompt_weekly.txt}"
  SUBJECT_PREFIX="${3:-每週 Java/Spring Boot 回顧}"
else
  PROMPT_FILE="${2:-prompt_daily.txt}"
  SUBJECT_PREFIX="${3:-每日 Java/Spring Boot}"
fi

MAX_TRIES=3
CLAUDE_TIMEOUT=600
NET_WAIT_MAX=24

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }
notify() { /usr/bin/osascript -e "display notification \"$2\" with title \"$1\" sound name \"Basso\"" >/dev/null 2>&1; }

period_key() { [ "$KIND" = "weekly" ] && date +%G-W%V || date +%F; }
MARKER="$STATE_DIR/${KIND}-$(period_key)"

if [ -f "$MARKER" ]; then
  log "SKIP: [$SUBJECT_PREFIX] 本週期已寄過（$(basename "$MARKER")），跳過。"
  exit 0
fi

wait_for_network() {
  local i=0
  until curl -sf --max-time 5 https://www.google.com/generate_204 >/dev/null 2>&1; do
    i=$((i+1))
    if [ $i -ge $NET_WAIT_MAX ]; then
      log "WARN: 網路在 $((NET_WAIT_MAX*5))s 內未就緒，本時段放棄。"
      return 1
    fi
    sleep 5
  done
  return 0
}

run_claude() {  # $1=prompt 字串 $2=輸出檔
  local prompt="$1" outfile="$2"
  : > "$outfile"
  "$CLAUDE" -p "$prompt" --model "$MODEL" --permission-mode default --output-format text > "$outfile" 2>>"$LOG" &
  local cpid=$!
  ( sleep "$CLAUDE_TIMEOUT"; kill -TERM "$cpid" 2>/dev/null ) &
  local wpid=$!
  wait "$cpid" 2>/dev/null
  local rc=$?
  kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
  return $rc
}

looks_like_html() {  # 給每週用：像 HTML 且不含錯誤字樣
  local out="$1"
  [ -n "$out" ] || return 1
  print -r -- "$out" | grep -q '<' || return 1
  print -r -- "$out" | grep -qiE 'API Error|socket connection|^Error:' && return 1
  return 0
}

echo "===== $(date '+%Y-%m-%d %H:%M:%S') 開始 [$SUBJECT_PREFIX] (kind=$KIND) =====" >> "$LOG"
BASE_PROMPT="$(cat "$DIR/$PROMPT_FILE")"

# ── 組 context（每日可能回報 FINISHED）──
if ! wait_for_network; then
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') 結束 (網路未就緒待補跑) =====" >> "$LOG"; exit 1
fi
CTX="$("$PYTHON" "$DIR/build_lesson.py" "$KIND" 2>>"$LOG")"

if [ "$KIND" = "daily" ] && print -r -- "$CTX" | grep -q '^STATUS: FINISHED'; then
  DONE_HTML='<div style="font-family:-apple-system,sans-serif;max-width:680px;margin:0 auto;color:#16213e;"><div style="font-size:20px;font-weight:800;">🎉 你已完成整份課綱！</div><p style="font-size:14px;line-height:1.7;color:#3b424f;">恭喜走完所有主題。可以編輯 syllabus.txt 加新主題，或開始循環複習。</p></div>'
  SEND_OUT="$(echo "$DONE_HTML" | "$PYTHON" "$DIR/send_email.py" "Java/Spring Boot 課綱完成" 2>&1)"; RC=$?
  echo "$SEND_OUT" >> "$LOG"
  [ $RC -eq 0 ] && date '+%Y-%m-%d %H:%M:%S' > "$MARKER" && log "INFO: 課綱已完成，寄出完成通知。"
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') 結束 (rc=$RC, 課綱完成) =====" >> "$LOG"; exit $RC
fi

# ── 呼叫 claude（重試）──
TMP_OUT="$(mktemp -t java-learn)"
RAW=""
attempt=1
while [ $attempt -le $MAX_TRIES ]; do
  PROMPT="$BASE_PROMPT"$'\n\n=== 今日課程資料 ===\n'"$CTX"
  run_claude "$PROMPT" "$TMP_OUT"; crc=$?
  OUT="$(cat "$TMP_OUT")"
  if [ "$KIND" = "daily" ]; then
    # 每日：用 apply_result 驗證模式解析出 html（不動狀態）
    if [ $crc -eq 0 ] && HTML="$(echo "$OUT" | "$PYTHON" "$DIR/apply_result.py" 2>>"$LOG")" && [ -n "$HTML" ]; then
      RAW="$OUT"; log "INFO: 第 $attempt 次成功解析。"; break
    fi
  else
    if [ $crc -eq 0 ] && looks_like_html "$OUT"; then
      HTML="$OUT"; RAW="$OUT"; log "INFO: 第 $attempt 次成功。"; break
    fi
  fi
  log "WARN: 第 $attempt/$MAX_TRIES 次失敗 (rc=$crc, 長度=${#OUT})，30s 後重試。"
  attempt=$((attempt+1)); [ $attempt -le $MAX_TRIES ] && sleep 30
done
rm -f "$TMP_OUT"

if [ -z "$RAW" ]; then
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') 結束 (rc=1, 失敗待補跑) =====" >> "$LOG"; exit 1
fi

# ── 寄信 ──
SEND_OUT="$(echo "$HTML" | "$PYTHON" "$DIR/send_email.py" "$SUBJECT_PREFIX" 2>&1)"; RC=$?
echo "$SEND_OUT" >> "$LOG"
if [ $RC -eq 0 ]; then
  date '+%Y-%m-%d %H:%M:%S' > "$MARKER"
  if [ "$KIND" = "daily" ]; then
    # 寄成功才推進度＋寫存檔（把同一份 claude 輸出餵 --commit）
    if ! echo "$RAW" | "$PYTHON" "$DIR/apply_result.py" --commit >>"$LOG" 2>&1; then
      log "WARN: 進度更新失敗（信已寄出，明天可能重複同一步）。"
    fi
  fi
  log "INFO: 已寄出並標記 $(basename "$MARKER")。"
else
  REASON="$(echo "$SEND_OUT" | grep -iE 'error' | tail -1 | tr -d '"\\' | cut -c1-180)"
  [ -z "$REASON" ] && REASON="請查看 run.log"
  notify "⚠️ 學習信寄送失敗" "$SUBJECT_PREFIX：$REASON"
  log "NOTIFY: 寄送失敗。原因：$REASON"
fi
echo "===== $(date '+%Y-%m-%d %H:%M:%S') 結束 (rc=$RC) =====" >> "$LOG"
exit $RC
```

- [ ] **Step 2: 設為可執行並做語法檢查**

Run: `chmod +x run_learn.sh && zsh -n run_learn.sh && echo "語法 OK"`
Expected: `語法 OK`

- [ ] **Step 3: Commit**

```bash
git add run_learn.sh
git commit -m "加入串接全流程的主腳本"
```

---

## Task 10: 排程安裝 `install.sh` 與 launchd 範本

**Files:**
- Create: `launchd/com.user.java-learn-daily.plist.template`
- Create: `launchd/com.user.java-learn-weekly.plist.template`
- Create: `install.sh`

- [ ] **Step 1: 寫每日 launchd 範本**（多時段，順著系統喚醒；`__PROJECT_DIR__` 由 install.sh 取代）

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.user.java-learn-daily</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>__PROJECT_DIR__/run_learn.sh</string>
    <string>daily</string>
  </array>
  <key>StartCalendarInterval</key>
  <array>
    <dict><key>Hour</key><integer>8</integer><key>Minute</key><integer>5</integer></dict>
    <dict><key>Hour</key><integer>9</integer><key>Minute</key><integer>30</integer></dict>
    <dict><key>Hour</key><integer>12</integer><key>Minute</key><integer>30</integer></dict>
    <dict><key>Hour</key><integer>19</integer><key>Minute</key><integer>0</integer></dict>
  </array>
  <key>StandardOutPath</key><string>__PROJECT_DIR__/launchd.out.log</string>
  <key>StandardErrorPath</key><string>__PROJECT_DIR__/launchd.err.log</string>
</dict>
</plist>
```

- [ ] **Step 2: 寫每週 launchd 範本**（週日多時段）

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.user.java-learn-weekly</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>__PROJECT_DIR__/run_learn.sh</string>
    <string>weekly</string>
  </array>
  <key>StartCalendarInterval</key>
  <array>
    <dict><key>Weekday</key><integer>0</integer><key>Hour</key><integer>9</integer><key>Minute</key><integer>0</integer></dict>
    <dict><key>Weekday</key><integer>0</integer><key>Hour</key><integer>13</integer><key>Minute</key><integer>0</integer></dict>
  </array>
  <key>StandardOutPath</key><string>__PROJECT_DIR__/launchd.out.log</string>
  <key>StandardErrorPath</key><string>__PROJECT_DIR__/launchd.err.log</string>
</dict>
</plist>
```

- [ ] **Step 3: 寫 `install.sh`**

```bash
#!/bin/zsh
# 安裝器：把 launchd 範本中的 __PROJECT_DIR__ 換成本專案絕對路徑，載入排程。
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
LA="$HOME/Library/LaunchAgents"
mkdir -p "$LA"

if [ ! -f "$DIR/config.env" ]; then
  echo "請先建立 config.env：cp config.env.example config.env 後填入設定。"
  exit 1
fi

for tmpl in "$DIR"/launchd/*.plist.template; do
  name="$(basename "${tmpl%.template}")"
  dest="$LA/$name"
  sed "s|__PROJECT_DIR__|$DIR|g" "$tmpl" > "$dest"
  launchctl unload "$dest" 2>/dev/null || true
  launchctl load "$dest"
  echo "已安裝排程：$name"
done

echo
echo "提醒：請先把 Gmail App Password 存進 Keychain（只需一次）："
echo "  security add-generic-password -a \"\$GMAIL_USER\" -s \"java-learn-gmail\" -w"
echo "立即測試：zsh $DIR/run_learn.sh daily"
```

- [ ] **Step 4: 設為可執行並語法檢查**

Run: `chmod +x install.sh && zsh -n install.sh && echo "語法 OK"`
Expected: `語法 OK`

- [ ] **Step 5: Commit**

```bash
git add install.sh launchd/
git commit -m "加入排程安裝器與 launchd 範本"
```

---

## Task 11: README、全測試、端到端煙霧測試、收尾

**Files:**
- Create: `README.md`
- 驗證：全 pytest、`build_lesson.py` 乾跑、`run_learn.sh` 結構檢查

- [ ] **Step 1: 寫 `README.md`**

````markdown
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
````

- [ ] **Step 2: 跑全部單元測試**

Run: `cd /Users/yeqilin/Workspace/java-learn-digest && python3 -m pytest -v`
Expected: PASS（palette / state_store / build_lesson / apply_result / send_email 全綠）

- [ ] **Step 3: `build_lesson.py` 乾跑（用暫時 state 驗證實際輸出）**

Run:
```bash
LEARN_GOAL="測試目標" python3 build_lesson.py daily \
  --syllabus syllabus.txt \
  --progress /tmp/jl_progress.json \
  --history /tmp/jl_history.jsonl
```
Expected: 印出含 `GOAL:`、`TOPIC: IoC 與依賴注入：為什麼不要自己 new`、`STEP: 1`、`YESTERDAY_SUMMARY: （無，這是第一課）`、`COLOR_BG: #...` 的 context（progress 不存在→用第一個主題）。

- [ ] **Step 4: 驗證「課綱走完」分支**

Run:
```bash
echo '{"current_index":999,"step":1,"covered":[],"completed_topics":[]}' > /tmp/jl_done.json
python3 build_lesson.py daily --syllabus syllabus.txt --progress /tmp/jl_done.json --history /tmp/jl_history.jsonl
```
Expected: 輸出 `STATUS: FINISHED`

- [ ] **Step 5: `run_learn.sh` 結構檢查（不真的寄信）**

Run: `zsh -n run_learn.sh && echo OK`
Expected: `OK`

> 真正的端到端寄信測試需要 `config.env` 與 Keychain 密碼，屬使用者環境設定，留待安裝後由使用者執行 `zsh run_learn.sh daily` 驗證（會實際寄一封到信箱）。

- [ ] **Step 6: 清理暫存並 Commit**

```bash
rm -f /tmp/jl_progress.json /tmp/jl_history.jsonl /tmp/jl_done.json
git add README.md
git commit -m "加入專案說明文件"
```

- [ ] **Step 7: （可選）清掉 spike 暫存**

Run: `rm -rf /Users/yeqilin/Workspace/java-learn-spike`
（spike 的調性已固化進 prompt 與版型；若想留作對照可略過此步。）

---

## 完成後的使用者驗收

1. `cp config.env.example config.env` 並填值；把 Gmail App Password 存進 Keychain。
2. `zsh run_learn.sh daily` → 應收到 Day 1（IoC 第 1 步）的信，且 `state/progress.json` 的 `step` 變成 2、`lessons/` 出現當日 markdown。
3. 再跑一次 `zsh run_learn.sh daily` → 應「秒跳過」（marker 已存在），不重複寄。
4. `./install.sh` 安裝排程，之後每天早上自動收信。
```
```
