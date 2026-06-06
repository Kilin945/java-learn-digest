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
