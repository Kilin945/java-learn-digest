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
