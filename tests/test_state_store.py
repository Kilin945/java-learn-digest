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
