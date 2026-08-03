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


# ── 佇列（一次備多天，離線期間靠庫存續命）──

def _item(index, step, summary="s"):
    return {"kind": "lesson", "index": index, "step": step,
            "result": dict(VALID, today_summary=summary)}


def test_load_queue_missing_file_is_empty(tmp_path):
    assert ar.load_queue(str(tmp_path / "state" / "outbox.json")) == []


def test_load_queue_accepts_legacy_single_object(tmp_path):
    """舊格式是單一物件。雲端可能還存著這種檔，讀不出來就等於漏信。"""
    p = str(tmp_path / "state" / "outbox.json")
    ar.save_outbox(p, _item(3, 2))
    assert ar.load_queue(p) == [_item(3, 2)]


def test_load_queue_ignores_broken_json(tmp_path):
    p = tmp_path / "outbox.json"
    p.write_text("{壞掉的", encoding="utf-8")
    assert ar.load_queue(str(p)) == []


def test_queue_roundtrip_preserves_order(tmp_path):
    p = str(tmp_path / "state" / "outbox.json")
    items = [_item(3, 2, "第一"), _item(3, 3, "第二"), _item(4, 1, "第三")]
    ar.save_queue(p, items)
    assert ar.load_queue(p) == items


def test_append_queue_adds_to_tail(tmp_path):
    p = str(tmp_path / "state" / "outbox.json")
    ar.append_queue(p, _item(3, 2, "先"))
    ar.append_queue(p, _item(3, 3, "後"))
    got = ar.load_queue(p)
    assert [i["result"]["today_summary"] for i in got] == ["先", "後"]


def test_pop_queue_removes_only_head(tmp_path):
    p = str(tmp_path / "state" / "outbox.json")
    ar.save_queue(p, [_item(3, 2, "頭"), _item(3, 3, "身")])
    ar.pop_queue(p)
    got = ar.load_queue(p)
    assert len(got) == 1
    assert got[0]["result"]["today_summary"] == "身"


def test_pop_queue_empty_removes_file(tmp_path):
    """清空後檔案要消失——14:00 體檢是靠「檔案不存在」判斷明天會沒信。"""
    p = str(tmp_path / "state" / "outbox.json")
    ar.save_queue(p, [_item(3, 2)])
    ar.pop_queue(p)
    assert ar.load_queue(p) == []
    import os
    assert not os.path.exists(p)
    ar.pop_queue(p)  # 空佇列再 pop 不應出錯


def _syllabus(tmp_path):
    p = tmp_path / "syllabus.txt"
    p.write_text("主題甲\n主題乙\n主題丙\n", encoding="utf-8")
    return str(p)


def test_queue_tail_progress_empty_queue_is_current(tmp_path):
    prog = {"current_index": 1, "step": 3, "covered": [], "completed_topics": []}
    out = ar.queue_tail_progress([], _syllabus(tmp_path), prog, "2026-08-04")
    assert (out["current_index"], out["step"]) == (1, 3)


def test_queue_tail_progress_advances_step_within_topic(tmp_path):
    """topic_complete=False 的那幾篇只是往下一步走，主題不換。"""
    prog = {"current_index": 1, "step": 3, "covered": [], "completed_topics": []}
    queue = [_item(1, 3), _item(1, 4)]  # 兩篇都沒收尾
    out = ar.queue_tail_progress(queue, _syllabus(tmp_path), prog, "2026-08-04")
    assert (out["current_index"], out["step"]) == (1, 5)


def test_queue_tail_progress_switches_topic_on_complete(tmp_path):
    """這是 step+1 推算會算錯的情形：收尾那篇會把主題推到下一個、step 歸 1。"""
    prog = {"current_index": 1, "step": 3, "covered": [], "completed_topics": []}
    done = _item(1, 3)
    done["result"] = dict(VALID, topic_complete=True, today_summary="收尾")
    out = ar.queue_tail_progress([done], _syllabus(tmp_path), prog, "2026-08-04")
    assert (out["current_index"], out["step"]) == (2, 1)


def test_queue_tail_history_appends_queue_summaries_with_dates(tmp_path):
    """週報要吃到還沒寄出的那幾篇，所以庫存也得帶著「預計寄出日」進歷史。"""
    prog = {"current_index": 1, "step": 3, "covered": [], "completed_topics": []}
    hist = [{"date": "2026-08-03", "topic": "主題甲", "step": 2, "summary": "已寄出的"}]
    queue = [_item(1, 3, "庫存第一"), _item(1, 4, "庫存第二")]
    rows = ar.queue_tail_history(queue, _syllabus(tmp_path), prog, hist, "2026-08-04")
    assert [r["summary"] for r in rows] == ["已寄出的", "庫存第一", "庫存第二"]
    # 每天寄一篇，日期從 first_send 依序往後
    assert [r["date"] for r in rows[1:]] == ["2026-08-04", "2026-08-05"]


def test_queue_head_ready_checks_first_item_only(tmp_path):
    """庫存第二篇對不上進度是正常的（它要等第一篇寄完才輪到），不該因此判定未備妥。"""
    progress = {"current_index": 3, "step": 2}
    queue = [_item(3, 2), _item(3, 3), _item(4, 1)]
    assert ar.outbox_ready(ar.queue_head(queue), progress) is True
    # 反過來：頭部對不上就是未備妥，即使後面有對得上的
    assert ar.outbox_ready(ar.queue_head([_item(9, 9), _item(3, 2)]), progress) is False
    assert ar.queue_head([]) is None
