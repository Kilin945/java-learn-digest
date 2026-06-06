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
