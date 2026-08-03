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
import re
import sys
import json
import argparse
from datetime import date, timedelta

import state_store as ss

REQUIRED = ("html", "topic_complete", "today_summary", "archive_markdown")

# 課通常在前一天備稿，html 標題裡的日期是產稿日；寄出時蓋成寄出當天。
_TITLE_DATE = re.compile(r"(每日 Java / Spring Boot · )\d{4}-\d{2}-\d{2}")


def restamp_send_date(html, today):
    return _TITLE_DATE.sub(lambda m: m.group(1) + today, html, count=1)


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


# ── 佇列：備妥待寄的稿，先進先出 ────────────────────────────
# 為什麼不是只放一篇：沒人補貨就會斷。庫存一篇的話，筆電關著或備稿失敗的隔天
# 雲端就沒東西可寄；2026-08 要離開十二天，只能一次把整段備滿。
#
# 刻意沿用「綁進度、不綁日期」：每篇認的是自己的 index/step，不是某月某日。
# 所以雲端漏掉一班（或某天寄失敗）庫存不會作廢，只是整串往後遞一天，
# progress、lessons/、history 三者仍然對得起來。ai-news 那邊相反——內容就是
# 當天新聞，綁週期代號、過期作廢，兩邊差異是刻意的，別互相套用。

def load_queue(path):
    """讀佇列，一律回傳 list（不存在或壞掉回空）。

    舊格式是單一物件，會被包成只有一篇的佇列——雲端可能還存著舊檔，
    讀不出來就等於漏信，所以這層相容不能省。
    """
    raw = load_outbox(path)
    if isinstance(raw, dict):
        return [raw]
    if isinstance(raw, list):
        return [i for i in raw if isinstance(i, dict)]
    return []


def save_queue(path, items):
    """整個佇列寫回檔案。"""
    save_outbox(path, list(items))


def append_queue(path, item):
    """追加一篇到尾端，回傳追加後的庫存數。"""
    items = load_queue(path)
    items.append(item)
    save_queue(path, items)
    return len(items)


def pop_queue(path):
    """丟掉頭部那篇（寄出成功後呼叫），回傳剩下的佇列。

    清空時把檔案刪掉，而不是留一個空陣列：14:00 的缺稿體檢是靠
    「outbox 不存在」判斷明天早上會沒信，留空檔會讓它看起來還有庫存。
    """
    items = load_queue(path)
    rest = items[1:]
    if rest:
        save_queue(path, rest)
    else:
        clear_outbox(path)
    return rest


def queue_head(items):
    """下一篇要寄的（佇列空回 None）。"""
    return items[0] if items else None


def _replay_queue(queue, syllabus, progress, first_send_date):
    """把庫存依序套一遍 advance_progress，回傳（尾端進度, 庫存各篇的歷史列）。

    批次備稿必須知道「這些庫存全部寄完後會走到哪」，才能接著產下一篇。
    不另存一份虛擬進度檔——佇列本身就記著每篇的 topic_complete，從真實
    progress replay 一遍即可，少一份會跟佇列對不起來的狀態。

    為什麼不能用 step+1 猜：收尾那篇（topic_complete=True）會換主題、step 歸 1。
    猜錯的下場是庫存頭部跟進度對不上，雲端判定未備妥，整串庫存全寄不出去。
    """
    prog = progress
    rows = []
    first = date.fromisoformat(first_send_date)
    for i, item in enumerate(queue):
        res = item.get("result") or {}
        topic = ss.current_topic(syllabus, prog) or "（課綱外）"
        # 每天寄一篇，所以第 i 篇的預計寄出日就是 first_send_date + i 天。
        send_day = (first + timedelta(days=i)).isoformat()
        rows.append({"date": send_day, "topic": topic,
                     "step": prog.get("step", 1),
                     "summary": res.get("today_summary", "")})
        prog = ss.advance_progress(prog, topic, res.get("today_summary", ""),
                                   res.get("topic_complete", False), send_day)
    return prog, rows


def queue_tail_progress(queue, syllabus_path, progress, first_send_date):
    """庫存全部寄完後的進度。"""
    prog, _ = _replay_queue(queue, ss.load_syllabus(syllabus_path), progress, first_send_date)
    return prog


def queue_tail_history(queue, syllabus_path, progress, history, first_send_date):
    """真實歷史 ＋ 庫存各篇（帶預計寄出日）。

    週報的回顧視窗是按日期篩的，而庫存還沒寄出、history 裡沒有它們；
    離開期間那封週報要涵蓋的七天有一半還在庫存裡，所以得把它們補進來。
    """
    _, rows = _replay_queue(queue, ss.load_syllabus(syllabus_path), progress, first_send_date)
    return list(history) + rows


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


# ── 狀態總覽 ─────────────────────────────────────────────────
# 跟 ai-news 的 outbox.py --status 對稱，存在理由一樣：回答「今天到底怎麼了」
# 不該需要人去翻 run.log。2026-07-31 在 ai-news 那邊就翻錯過一次——用 tail 看，
# 真正那筆「完成」被後面一輪輪的略過紀錄擠掉，誤報成排程沒跑。
#
# 這裡的語意跟 ai-news 不同，不要混淆：
#   ai-news 的 outbox 是「今天的稿」，綁週期代號，過期作廢。
#   java 的 outbox 是「下一篇」，綁進度(index/step)不綁日期，前一天備好隔天寄。
#   所以「今天寄了沒」要看 daily-<日期> marker，不是看 outbox。

_JAVA_RUN = re.compile(r"^===== (\d{4}-\d{2}-\d{2}) (\d\d:\d\d:\d\d) (開始|結束) \[mode=([\w-]+)")


def _runs_today(here, today):
    """今天每一次執行的 (mode, 起, 訖)。整份讀進來過濾，不用 tail。"""
    try:
        with open(os.path.join(here, "run.log"), encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
    except OSError:
        return []
    runs, pending = [], {}
    for line in lines:
        m = _JAVA_RUN.match(line)
        if not m or m.group(1) != today:
            continue
        day, clock, phase, mode = m.groups()
        if phase == "開始":
            pending[mode] = clock
        elif mode in pending:
            runs.append((mode, pending.pop(mode), clock))
    return runs


def status(args, here):
    state_dir = os.path.dirname(os.path.abspath(args.progress))
    today = date.today()
    today_s = today.isoformat()
    week = "一二三四五六日"[today.weekday()]
    wk = today.strftime("%G-W%V")

    print(f"{today_s}（週{week}）{__import__('datetime').datetime.now():%H:%M}")
    print(f"state: {os.path.realpath(state_dir)}")
    print()

    # 今天的課寄出去了沒：marker 由 run_learn.sh 在「確認寄信成功後」才寫，可信。
    marker = os.path.join(state_dir, f"daily-{today_s}")
    if os.path.exists(marker):
        with open(marker, encoding="utf-8") as f:
            print(f"  今日課程  ✅ 已寄出 {f.read().strip()}")
    else:
        print(f"  今日課程  ❌ 今天還沒寄出")

    # 下一篇（明天要寄的）備妥了沒，以及庫存還能撐幾天。
    progress = ss.load_progress(args.progress)
    queue = load_queue(args.outbox)
    head = queue_head(queue)
    idx, step = progress.get("current_index", 0), progress.get("step", 1)
    if outbox_ready(head, progress):
        print(f"  下一篇    ✅ 已備妥（第 {idx} 課 · step {step}）")
    elif head is None:
        print(f"  下一篇    ❌ 未備妥（outbox 不存在）")
    else:
        print(f"  下一篇    ❌ 未備妥（佇列頭部是第 {head.get('index')} 課 step "
              f"{head.get('step')}，進度已走到第 {idx} 課 step {step}）")
    if len(queue) > 1:
        # 每天寄一篇，所以庫存篇數就是還能撐幾天。
        last = (date.today() + timedelta(days=len(queue))).isoformat()
        print(f"  庫存      📦 {len(queue)} 篇（每天一篇，可撐到 {last} 早上）")

    # 週報：週五備稿、週六由雲端寄。
    box_wk = ""
    try:
        with open(os.path.join(state_dir, "weekly_outbox.week"), encoding="utf-8") as f:
            box_wk = f.read().strip()
    except OSError:
        pass
    sent_wk = os.path.exists(os.path.join(state_dir, f"weekly-{wk}"))
    if sent_wk:
        print(f"  週報      ✅ 本週（{wk}）已寄出")
    elif box_wk == wk:
        print(f"  週報      ✅ 已備妥（{wk}），待週六寄出")
    else:
        print(f"  週報      ⏸  尚未備稿（本週 {wk}，備稿日週五／六）")

    topic = ss.current_topic(ss.load_syllabus(args.syllabus), progress) or "（課綱外）"
    print(f"  進度      第 {idx} 課 · step {step} — {topic}")
    print()

    runs = _runs_today(here, today_s)
    if runs:
        print("  今天的執行：")
        for mode, start, end in runs[-4:]:
            print(f"    {mode:<14} {start} → {end}")
        if len(runs) > 4:
            print(f"    （今天共 {len(runs)} 次，只列最後 4 次）")
    else:
        print("  今天的執行：沒有紀錄")
    return 0


def main(argv=None):
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--to-outbox", action="store_true", help="解析 stdin 並存進 outbox（覆寫整個佇列）")
    g.add_argument("--append-outbox", action="store_true", help="解析 stdin 並追加到佇列尾端（批次備稿用）")
    g.add_argument("--queue-len", action="store_true", help="印出目前庫存幾篇")
    g.add_argument("--queue-tail-state", metavar="DIR",
                   help="把「庫存全寄完後的進度／歷史」寫進 DIR（批次備稿組 context 用）")
    g.add_argument("--outbox-ready", action="store_true", help="outbox 備妥且相符則 exit 0")
    g.add_argument("--outbox-html", action="store_true", help="印出 outbox 的 html")
    g.add_argument("--commit-outbox", action="store_true", help="用 outbox 推進度並清空")
    g.add_argument("--commit", action="store_true", help="（舊）解析 stdin 並直接推進度")
    g.add_argument("--status", action="store_true", help="今天的狀態總覽（不動任何東西）")
    ap.add_argument("--syllabus", default=os.path.join(here, "syllabus.txt"))
    ap.add_argument("--progress", default=os.path.join(here, "state", "progress.json"))
    ap.add_argument("--history", default=os.path.join(here, "state", "history.jsonl"))
    ap.add_argument("--lessons-dir", default=os.path.join(here, "lessons"))
    ap.add_argument("--outbox", default=os.path.join(here, "state", "outbox.json"))
    # 批次備稿時由呼叫端算出每篇的位置（虛擬進度），不指定就沿用 progress.json。
    ap.add_argument("--index", type=int, default=None, help="這篇對應的主題序號（預設取自 progress）")
    ap.add_argument("--step", type=int, default=None, help="這篇對應的第幾步（預設取自 progress）")
    ap.add_argument("--first-send", default=None,
                    help="庫存第一篇的預計寄出日 YYYY-MM-DD（預設明天）")
    args = ap.parse_args(argv)

    # ── 不讀 stdin 的查詢/動作 ──
    if args.status:
        sys.exit(status(args, here))

    if args.queue_len:
        print(len(load_queue(args.outbox)))
        return

    if args.queue_tail_state:
        # 批次備稿用：把「庫存全寄完後的狀態」寫成一份暫存 state，
        # build_lesson.py 直接指向它就能組出下一篇的 context，本身不必改。
        # 這份是推算出來的，絕不能寫回真的 state/——真正的進度推進只由
        # 雲端寄出後的 --commit-outbox 負責。
        progress = ss.load_progress(args.progress)
        history = ss.load_history(args.history)
        queue = load_queue(args.outbox)
        first = args.first_send or (date.today() + timedelta(days=1)).isoformat()
        tail_prog = queue_tail_progress(queue, args.syllabus, progress, first)
        tail_hist = queue_tail_history(queue, args.syllabus, progress, history, first)
        os.makedirs(args.queue_tail_state, exist_ok=True)
        ss.save_progress(os.path.join(args.queue_tail_state, "progress.json"), tail_prog)
        with open(os.path.join(args.queue_tail_state, "history.jsonl"), "w", encoding="utf-8") as f:
            for row in tail_hist:
                f.write(json.dumps(row, ensure_ascii=False) + "\n")
        print(f"OK: 庫存 {len(queue)} 篇寄完後會走到第 {tail_prog.get('current_index')} 課 "
              f"step {tail_prog.get('step')}（暫存於 {args.queue_tail_state}）", file=sys.stderr)
        return

    if args.outbox_ready:
        progress = ss.load_progress(args.progress)
        queue = load_queue(args.outbox)
        head = queue_head(queue)
        ok = outbox_ready(head, progress)
        if not ok:  # 把「為何未備妥」寫到 stderr，呼叫端導進 log 供事後驗證
            if head is None:
                print("outbox-ready: outbox 不存在或無法解析", file=sys.stderr)
            else:
                print(f"outbox-ready: 佇列頭部(index={head.get('index')},step={head.get('step')})"
                      f" 與進度(index={progress.get('current_index')},step={progress.get('step')}) 不符"
                      f"（庫存 {len(queue)} 篇）", file=sys.stderr)
        sys.exit(0 if ok else 1)

    if args.outbox_html:
        head = queue_head(load_queue(args.outbox))
        if not head or not isinstance(head.get("result"), dict):
            print("ERROR: outbox 尚未備妥", file=sys.stderr)
            sys.exit(2)
        sys.stdout.write(restamp_send_date(head["result"]["html"],
                                           date.today().isoformat()))
        return

    if args.commit_outbox:
        head = queue_head(load_queue(args.outbox))
        if not head or not isinstance(head.get("result"), dict):
            print("ERROR: outbox 尚未備妥，無法 commit", file=sys.stderr)
            sys.exit(2)
        commit(head["result"], args.syllabus, args.progress, args.history,
               args.lessons_dir, date.today().isoformat())
        rest = pop_queue(args.outbox)
        print(f"OK: 已用 outbox 推進度，庫存剩 {len(rest)} 篇", file=sys.stderr)
        return

    # ── 以下需讀 stdin（claude 輸出）──
    try:
        res = parse_result(sys.stdin.read())
    except ValueError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(2)

    if args.to_outbox or args.append_outbox:
        progress = ss.load_progress(args.progress)
        # index/step 可由呼叫端指定：批次備稿時每篇對應的是「虛擬進度」（前面幾篇
        # 寄出後才會走到的位置），不是 progress.json 現在的值。
        item = {
            "kind": "lesson",
            "index": args.index if args.index is not None else progress.get("current_index", 0),
            "step": args.step if args.step is not None else progress.get("step", 1),
            "result": res,
        }
        if args.append_outbox:
            n = append_queue(args.outbox, item)
            print(f"OK: 已追加進佇列（庫存 {n} 篇）", file=sys.stderr)
        else:
            # --to-outbox 是覆寫語意：只有在佇列頭部對不上進度（異常狀態）時
            # run_learn.sh 才會重產並走到這裡，此時舊的壞資料就該被整批換掉。
            save_queue(args.outbox, [item])
            print("OK: 已存進 outbox（備妥待寄）", file=sys.stderr)
    elif args.commit:
        commit(res, args.syllabus, args.progress, args.history,
               args.lessons_dir, date.today().isoformat())
        print("OK: 已更新進度與存檔", file=sys.stderr)
    else:
        sys.stdout.write(res["html"])


if __name__ == "__main__":
    main()
