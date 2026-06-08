#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""解析 claude 每日輸出的 JSON，並管理「備妥待寄」的 outbox。

設計：把「慢的產生（claude）」和「快的寄出（SMTP）」徹底分開，
讓寄出能塞進闔蓋喚醒只有數十秒的時間窗，手機才能準時收到。

從 stdin 讀 claude 輸出時：
  預設            ：解析＋驗證後把 html 印到 stdout（不動狀態）。
  --to-outbox     ：解析＋驗證後存進 outbox（標記它對應目前進度的 index/step），不寄、不推進度。

不讀 stdin 的查詢/動作：
  --outbox-ready  ：outbox 是否已備妥且與目前進度相符 → 相符 exit 0，否則 exit 1。
  --outbox-html   ：把 outbox 裡的 html 印到 stdout（給寄信用）。
  --commit-outbox ：寄信成功後呼叫 → 用 outbox 內容推進度、寫 lessons/<date>.md、清空 outbox。

解析/驗證失敗 → 印錯誤到 stderr 並以非 0 結束。
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
        # strict=False 允許字串內含原始換行/Tab —— claude 常把 html 值排成多行，
        # 嚴格 JSON 會視為「非法控制字元」而拒收。
        data = json.loads(s, strict=False)
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


# ── outbox：備妥待寄的那一篇 ──

def load_outbox(path):
    """讀 outbox.json；不存在或壞掉回傳 None。"""
    if not os.path.exists(path):
        return None
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (json.JSONDecodeError, ValueError, OSError):
        return None


def save_outbox(path, payload):
    """寫 outbox.json，自動建立巢狀目錄。"""
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)


def clear_outbox(path):
    """刪掉 outbox.json（已寄出後）。不存在也沒關係。"""
    try:
        os.remove(path)
    except FileNotFoundError:
        pass


def outbox_ready(outbox, progress):
    """outbox 是否備妥、且正好對應目前進度（避免寄到過時的內容）。"""
    if not outbox or not isinstance(outbox.get("result"), dict):
        return False
    return (outbox.get("index") == progress.get("current_index")
            and outbox.get("step") == progress.get("step"))


def commit(res, syllabus_path, progress_path, history_path, lessons_dir, today):
    """用一份結果推進度、寫存檔、記歷史（寄信成功後才呼叫）。"""
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
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--to-outbox", action="store_true", help="解析 stdin 並存進 outbox")
    g.add_argument("--outbox-ready", action="store_true", help="outbox 備妥且相符則 exit 0")
    g.add_argument("--outbox-html", action="store_true", help="印出 outbox 的 html")
    g.add_argument("--commit-outbox", action="store_true", help="用 outbox 推進度並清空")
    g.add_argument("--commit", action="store_true", help="（舊）解析 stdin 並直接推進度")
    ap.add_argument("--syllabus", default=os.path.join(here, "syllabus.txt"))
    ap.add_argument("--progress", default=os.path.join(here, "state", "progress.json"))
    ap.add_argument("--history", default=os.path.join(here, "state", "history.jsonl"))
    ap.add_argument("--lessons-dir", default=os.path.join(here, "lessons"))
    ap.add_argument("--outbox", default=os.path.join(here, "state", "outbox.json"))
    args = ap.parse_args(argv)

    # ── 不讀 stdin 的查詢/動作 ──
    if args.outbox_ready:
        progress = ss.load_progress(args.progress)
        sys.exit(0 if outbox_ready(load_outbox(args.outbox), progress) else 1)

    if args.outbox_html:
        outbox = load_outbox(args.outbox)
        if not outbox or not isinstance(outbox.get("result"), dict):
            print("ERROR: outbox 尚未備妥", file=sys.stderr)
            sys.exit(2)
        sys.stdout.write(outbox["result"]["html"])
        return

    if args.commit_outbox:
        outbox = load_outbox(args.outbox)
        if not outbox or not isinstance(outbox.get("result"), dict):
            print("ERROR: outbox 尚未備妥，無法 commit", file=sys.stderr)
            sys.exit(2)
        commit(outbox["result"], args.syllabus, args.progress, args.history,
               args.lessons_dir, date.today().isoformat())
        clear_outbox(args.outbox)
        print("OK: 已用 outbox 推進度並清空", file=sys.stderr)
        return

    # ── 以下需讀 stdin（claude 輸出）──
    try:
        res = parse_result(sys.stdin.read())
    except ValueError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(2)

    if args.to_outbox:
        progress = ss.load_progress(args.progress)
        save_outbox(args.outbox, {
            "kind": "lesson",
            "index": progress.get("current_index", 0),
            "step": progress.get("step", 1),
            "result": res,
        })
        print("OK: 已存進 outbox（備妥待寄）", file=sys.stderr)
    elif args.commit:
        commit(res, args.syllabus, args.progress, args.history,
               args.lessons_dir, date.today().isoformat())
        print("OK: 已更新進度與存檔", file=sys.stderr)
    else:
        sys.stdout.write(res["html"])


if __name__ == "__main__":
    main()
