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


def test_parse_accepts_raw_newlines_in_html():
    # claude 常把 html 值排成多行（字串內含原始換行）；strict=False 才收得下
    text = '{"html": "<div>\n  <p>hi</p>\n</div>", "topic_complete": false, "today_summary": "s", "archive_markdown": "## x"}'
    res = ar.parse_result(text)
    assert "<p>hi</p>" in res["html"]
    assert "\n" in res["html"]


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
