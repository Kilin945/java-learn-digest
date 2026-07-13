#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把一篇 lessons/<date>.md 同步成「Spring 學習筆記」底下的一個子頁面。

設計重點：
- 背景 launchd 環境用不了互動式 Notion MCP，改用 Notion 內部整合 (internal integration)
  的 REST API（token 放 Keychain，跟 Gmail App Password 一樣）。
- 去重：建立前先掃父頁的子頁面，若已有同日標題就跳過 → 重跑安全、不會重複建。
- 只依賴標準函式庫（urllib），不裝額外套件。

用法：
  python3 sync_notion.py --md lessons/2026-06-07.md --date 2026-06-07
  （NOTION_PARENT_PAGE_ID 由 config.env 提供；token 由 Keychain / NOTION_TOKEN 提供）
"""
import os
import re
import sys
import json
import argparse
import subprocess
import urllib.request
import urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
NOTION_VERSION = "2022-06-28"
API = "https://api.notion.com/v1"


# ── 設定與憑證 ──

def load_config():
    cfg = {}
    p = os.path.join(HERE, "config.env")
    if os.path.exists(p):
        with open(p, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                cfg[k.strip()] = v.strip().strip('"').strip("'")
    return cfg


_CFG = load_config()


def conf(key, default=None):
    return os.environ.get(key) or _CFG.get(key, default)


def get_token():
    t = os.environ.get("NOTION_TOKEN")
    if t:
        return t.strip()
    account = conf("GMAIL_USER", "")
    service = conf("NOTION_KEYCHAIN_SERVICE", "java-learn-notion")
    try:
        r = subprocess.run(
            ["security", "find-generic-password", "-a", account, "-s", service, "-w"],
            capture_output=True, text=True,
        )
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip()
    except OSError:
        pass
    sys.exit(
        "ERROR: 找不到 Notion token。請先存進 Keychain：\n"
        f'  security add-generic-password -a "{account}" -s "{service}" -w\n'
        "（或設環境變數 NOTION_TOKEN）"
    )


# ── HTTP ──

def _req(method, url, token, payload=None):
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Notion-Version", NOTION_VERSION)
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        sys.exit(f"ERROR: Notion API {e.code} {method} {url}\n{body}")
    except urllib.error.URLError as e:
        sys.exit(f"ERROR: 連不上 Notion API：{e}")


# ── 行內 rich_text：解析 **粗體** 與 `行內碼` ──

_INLINE = re.compile(r"(\*\*.+?\*\*|`[^`]+`)")


def rich_text(text):
    out = []
    pos = 0
    for m in _INLINE.finditer(text):
        if m.start() > pos:
            out.append(_rt(text[pos:m.start()]))
        tok = m.group(0)
        if tok.startswith("**"):
            out.append(_rt(tok[2:-2], bold=True))
        else:
            out.append(_rt(tok[1:-1], code=True))
        pos = m.end()
    if pos < len(text):
        out.append(_rt(text[pos:]))
    out = [o for o in out if o["text"]["content"]]
    return out or [_rt(text)]


def _rt(content, bold=False, code=False):
    content = content[:2000]  # Notion 單一 rich_text 上限
    o = {"type": "text", "text": {"content": content}}
    ann = {}
    if bold:
        ann["bold"] = True
    if code:
        ann["code"] = True
    if ann:
        o["annotations"] = ann
    return o


# ── 區塊 ──

def _block(btype, **body):
    return {"object": "block", "type": btype, btype: body}


def _split_row(line):
    return [c.strip() for c in line.strip().strip("|").split("|")]


def md_to_blocks(md):
    lines = md.split("\n")
    blocks = []
    i, n = 0, len(lines)
    while i < n:
        raw = lines[i]
        s = raw.strip()
        if not s:
            i += 1
            continue

        # 程式碼區塊 ```lang
        if s.startswith("```"):
            lang = s[3:].strip() or "plain text"
            code = []
            i += 1
            while i < n and not lines[i].strip().startswith("```"):
                code.append(lines[i])
                i += 1
            i += 1  # 跳過結尾 ```
            blocks.append(_block(
                "code",
                rich_text=[_rt("\n".join(code)[:2000])],
                language=_norm_lang(lang),
            ))
            continue

        # 表格：本行以 | 開頭，下一行是 |---| 分隔列
        if s.startswith("|") and i + 1 < n and re.match(r"^\s*\|[\s:\-|]+\|\s*$", lines[i + 1]):
            header = _split_row(s)
            i += 2
            rows = [header]
            while i < n and lines[i].strip().startswith("|"):
                rows.append(_split_row(lines[i].strip()))
                i += 1
            width = len(header)
            children = []
            for r in rows:
                cells = [(r[c] if c < len(r) else "") for c in range(width)]
                children.append(_block("table_row", cells=[rich_text(c) for c in cells]))
            blocks.append(_block(
                "table",
                table_width=width,
                has_column_header=True,
                has_row_header=False,
                children=children,
            ))
            continue

        # 標題
        if s.startswith("### "):
            blocks.append(_block("heading_3", rich_text=rich_text(s[4:])))
            i += 1
            continue
        if s.startswith("## "):
            blocks.append(_block("heading_2", rich_text=rich_text(s[3:])))
            i += 1
            continue
        if s.startswith("# "):
            blocks.append(_block("heading_1", rich_text=rich_text(s[2:])))
            i += 1
            continue

        # 引用
        if s.startswith("> "):
            blocks.append(_block("quote", rich_text=rich_text(s[2:])))
            i += 1
            continue

        # 分隔線
        if s in ("---", "***", "___"):
            blocks.append(_block("divider"))
            i += 1
            continue

        # 有序清單
        m = re.match(r"^\d+\.\s+(.*)", s)
        if m:
            blocks.append(_block("numbered_list_item", rich_text=rich_text(m.group(1))))
            i += 1
            continue

        # 無序清單
        if s.startswith("- ") or s.startswith("* "):
            blocks.append(_block("bulleted_list_item", rich_text=rich_text(s[2:])))
            i += 1
            continue

        # 一般段落
        blocks.append(_block("paragraph", rich_text=rich_text(s)))
        i += 1
    return blocks


_LANG_MAP = {
    "java": "java", "json": "json", "bash": "bash", "sh": "shell",
    "shell": "shell", "sql": "sql", "xml": "xml", "yaml": "yaml",
    "yml": "yaml", "kotlin": "kotlin", "groovy": "groovy",
    "javascript": "javascript", "js": "javascript", "python": "python",
    "html": "html",
}

# Notion code block 接受的語言；其餘一律降級 plain text，避免單一冷門語言（如 properties）害整頁 400。
_NOTION_LANGS = {
    "abap", "abc", "agda", "arduino", "ascii art", "assembly", "bash", "basic", "bnf",
    "c", "c#", "c++", "clojure", "coffeescript", "coq", "css", "dart", "dhall", "diff",
    "docker", "ebnf", "elixir", "elm", "erlang", "f#", "flow", "fortran", "gherkin",
    "glsl", "go", "graphql", "groovy", "haskell", "hcl", "html", "idris", "java",
    "javascript", "json", "julia", "kotlin", "latex", "less", "lisp", "livescript",
    "llvm ir", "lua", "makefile", "markdown", "markup", "matlab", "mathematica",
    "mermaid", "nix", "notion formula", "objective-c", "ocaml", "pascal", "perl",
    "php", "plain text", "powershell", "prolog", "protobuf", "purescript", "python",
    "r", "racket", "reason", "ruby", "rust", "sass", "scala", "scheme", "scss",
    "shell", "smalltalk", "solidity", "sql", "swift", "toml", "typescript", "vb.net",
    "verilog", "vhdl", "visual basic", "webassembly", "xml", "yaml", "java/c/c++/c#",
}


def _norm_lang(lang):
    # 先套別名（js→javascript…），再用白名單守門：不合法就降級 plain text。
    v = _LANG_MAP.get(lang.lower(), lang.lower())
    return v if v in _NOTION_LANGS else "plain text"


# ── 標題推導 ──

def derive_title(md, date_str):
    for line in md.split("\n"):
        s = line.strip()
        if s.startswith("## "):
            return f"{date_str} · {s[3:].strip()}"
    return date_str


# ── 去重：父頁是否已有同日子頁 ──

def child_exists(token, parent_id, title, date_str):
    url = f"{API}/blocks/{parent_id}/children?page_size=100"
    while url:
        res = _req("GET", url, token)
        for b in res.get("results", []):
            if b.get("type") == "child_page":
                t = b["child_page"].get("title", "")
                if t == title or t.startswith(date_str):
                    return True
        if res.get("has_more") and res.get("next_cursor"):
            url = f"{API}/blocks/{parent_id}/children?page_size=100&start_cursor={res['next_cursor']}"
        else:
            url = None
    return False


# ── 建立子頁（>100 區塊自動分批 append）──

def create_child_page(token, parent_id, title, blocks):
    first, rest = blocks[:100], blocks[100:]
    page = _req("POST", f"{API}/pages", token, {
        "parent": {"page_id": parent_id},
        "properties": {"title": {"title": [{"text": {"content": title[:2000]}}]}},
        "children": first,
    })
    page_id = page["id"]
    while rest:
        batch, rest = rest[:100], rest[100:]
        _req("PATCH", f"{API}/blocks/{page_id}/children", token, {"children": batch})
    return page.get("url", page_id)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--md", required=True, help="課程 markdown 檔路徑")
    ap.add_argument("--date", required=True, help="日期 YYYY-MM-DD（當標題前綴與去重鍵）")
    ap.add_argument("--parent", default=None, help="父頁 page_id（預設讀 config 的 NOTION_PARENT_PAGE_ID）")
    args = ap.parse_args()

    parent_id = args.parent or conf("NOTION_PARENT_PAGE_ID")
    if not parent_id:
        sys.exit("ERROR: 未設定 NOTION_PARENT_PAGE_ID（請寫進 config.env 或用 --parent 傳入）")

    if not os.path.exists(args.md):
        sys.exit(f"ERROR: 找不到課程檔：{args.md}")
    with open(args.md, encoding="utf-8") as f:
        md = f.read().strip()
    if not md:
        sys.exit(f"ERROR: 課程檔是空的：{args.md}")

    token = get_token()
    title = derive_title(md, args.date)

    if child_exists(token, parent_id, title, args.date):
        print(f"SKIP: 「{title}」已存在，跳過。", file=sys.stderr)
        return

    blocks = md_to_blocks(md)
    url = create_child_page(token, parent_id, title, blocks)
    print(f"OK: 已建立子頁「{title}」 → {url}", file=sys.stderr)


if __name__ == "__main__":
    main()
