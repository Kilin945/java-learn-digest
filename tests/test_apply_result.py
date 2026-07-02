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


def test_outbox_save_load_clear_roundtrip(tmp_path):
    p = str(tmp_path / "state" / "outbox.json")
    payload = {"kind": "lesson", "index": 0, "step": 2, "result": VALID}
    ar.save_outbox(p, payload)
    assert ar.load_outbox(p) == payload
    ar.clear_outbox(p)
    assert ar.load_outbox(p) is None
    ar.clear_outbox(p)  # 再清一次不應出錯


def test_outbox_ready_matches_current_progress():
    progress = {"current_index": 0, "step": 2}
    ok = {"kind": "lesson", "index": 0, "step": 2, "result": VALID}
    assert ar.outbox_ready(ok, progress) is True
    # 步數對不上 → 不算備妥（避免寄到過時內容）
    assert ar.outbox_ready({"kind": "lesson", "index": 0, "step": 1, "result": VALID}, progress) is False
    # 主題對不上
    assert ar.outbox_ready({"kind": "lesson", "index": 1, "step": 2, "result": VALID}, progress) is False
    # 沒內容
    assert ar.outbox_ready(None, progress) is False
    assert ar.outbox_ready({"kind": "lesson", "index": 0, "step": 2}, progress) is False


def test_restamp_replaces_title_date_with_send_date():
    html = ('<div style="...">📘 每日 Java / Spring Boot · 2026-07-01</div>'
            '<p>內文提到 2026-07-01 的其他日期不該被動到</p>')
    out = ar.restamp_send_date(html, "2026-07-02")
    assert "每日 Java / Spring Boot · 2026-07-02" in out
    assert "內文提到 2026-07-01 的其他日期不該被動到" in out


def test_restamp_leaves_html_without_title_untouched():
    html = "<div>沒有標題行的內容</div>"
    assert ar.restamp_send_date(html, "2026-07-02") == html


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
