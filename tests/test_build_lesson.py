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


# ── 題庫驅動：syllabus 每行「題號｜題目」，題號去 questions.json 撈錨點與參考答案 ──

import json


def _bank(tmp_path, questions):
    p = tmp_path / "questions.json"
    p.write_text(json.dumps({"meta": {}, "questions": questions}, ensure_ascii=False),
                 encoding="utf-8")
    return str(p)


def test_question_id_parses_prefix_before_fullwidth_bar():
    assert bl.question_id("B8｜abstract class 與 interface 差在哪？") == "B8"


def test_question_id_strips_part_number():
    assert bl.question_id("G1-2｜手寫插入排序") == "G1"


def test_question_id_none_for_plain_topic():
    assert bl.question_id("IoC 與依賴注入：為什麼不要自己 new") is None


def test_part_info_numbers_this_part_among_same_question():
    syl = ["G1-1｜分出 null", "G1-2｜插入排序", "G1-3｜變形", "B8-1｜interface"]
    info = bl.part_info(syl, "G1-2｜插入排序")
    assert info["part"] == 2 and info["total"] == 3
    assert info["scope"] == "插入排序"
    assert info["others"] == ["第 1 篇：分出 null", "第 3 篇：變形"]


def test_part_info_none_for_single_line_question():
    assert bl.part_info(["B8｜整題"], "B8｜整題") is None


def test_daily_context_includes_part_fields():
    ctx = bl.format_daily_context(
        goal="g", topic="G1-2｜插入排序", step=1, covered=[], yesterday=None,
        color=("#a", "#b", "#c"), today="2026-10-27",
        question={"id": "G1", "q": "排序含 null"},
        part={"part": 2, "total": 3, "scope": "插入排序", "others": ["第 1 篇：分出 null"]},
    )
    assert "QUESTION: 排序含 null" in ctx
    assert "PART: 2/3" in ctx
    assert "PART_SCOPE: 插入排序" in ctx
    assert "- 第 1 篇：分出 null" in ctx


def test_load_question_finds_by_id(tmp_path):
    path = _bank(tmp_path, [{"id": "A1", "q": "IoC?"}, {"id": "B8", "q": "abstract?"}])
    assert bl.load_question(path, "B8")["q"] == "abstract?"


def test_load_question_none_when_bank_missing_or_id_unknown(tmp_path):
    assert bl.load_question(str(tmp_path / "nope.json"), "B8") is None
    path = _bank(tmp_path, [{"id": "A1", "q": "IoC?"}])
    assert bl.load_question(path, "Z9") is None


def test_daily_context_includes_question_bank_fields():
    q = {"id": "B8", "q": "abstract vs interface", "anchor": "Groovy 電文骨架",
         "answer_30s": "骨架用 abstract", "trap": "追問 default method",
         "trap_answer": "Java 8 起 interface 可有實作", "code": "abstract class X {}"}
    ctx = bl.format_daily_context(
        goal="g", topic="B8｜abstract vs interface", step=1, covered=[], yesterday=None,
        color=("#a", "#b", "#c"), today="2026-10-23", question=q,
    )
    assert "QUESTION_ID: B8" in ctx
    assert "ANCHOR: Groovy 電文骨架" in ctx
    assert "REFERENCE_ANSWER: 骨架用 abstract" in ctx
    assert "TRAP: 追問 default method" in ctx
    assert "TRAP_ANSWER: Java 8 起 interface 可有實作" in ctx
    assert "abstract class X {}" in ctx


def test_daily_context_without_question_has_no_bank_fields():
    ctx = bl.format_daily_context(
        goal="g", topic="t", step=1, covered=[], yesterday=None,
        color=("#a", "#b", "#c"), today="2026-10-23",
    )
    assert "QUESTION_ID" not in ctx
