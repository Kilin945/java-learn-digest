#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""學習信寄送：從 stdin 讀 HTML，透過 Gmail SMTP (STARTTLS) 寄出。
設定優先序：環境變數 > 同目錄 config.env。App Password 從 macOS Keychain 讀。
用法：echo "<html>" | python3 send_email.py ["主旨前綴"]
"""
import os
import sys
import ssl
import smtplib
import datetime
import subprocess
from email.mime.text import MIMEText
from email.utils import formataddr

SMTP_HOST = "smtp.gmail.com"
SMTP_PORT = 587
_CONFIG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.env")


def load_config():
    cfg = {}
    if os.path.exists(_CONFIG_PATH):
        with open(_CONFIG_PATH, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                cfg[k.strip()] = os.path.expandvars(v.strip().strip('"').strip("'"))

    def get(key, default=None):
        return os.environ.get(key) or cfg.get(key) or default

    return {
        "GMAIL_USER": get("GMAIL_USER"),
        "MAIL_TO": get("MAIL_TO") or get("GMAIL_USER"),
        "KEYCHAIN_SERVICE": get("KEYCHAIN_SERVICE", "java-learn-gmail"),
    }


def get_app_password(gmail_user, service):
    # 雲端（GitHub Actions）讀不到 macOS Keychain，優先吃環境變數；本機則回退 Keychain。
    env_pw = os.environ.get("GMAIL_APP_PASSWORD")
    if env_pw:
        return env_pw.strip()
    try:
        out = subprocess.run(
            ["security", "find-generic-password", "-a", gmail_user, "-s", service, "-w"],
            check=True, capture_output=True, text=True,
        )
        return out.stdout.strip()
    except FileNotFoundError:
        print("ERROR: 找不到 security 指令且未設 GMAIL_APP_PASSWORD 環境變數。", file=sys.stderr)
        sys.exit(3)
    except subprocess.CalledProcessError as e:
        print(f"ERROR: 無法從 Keychain 讀取密碼: {e.stderr.strip()}", file=sys.stderr)
        sys.exit(3)


def main():
    conf = load_config()
    if not conf["GMAIL_USER"]:
        print("ERROR: 未設定 GMAIL_USER（請建立 config.env，參考 config.env.example）", file=sys.stderr)
        sys.exit(4)

    html_body = sys.stdin.read()
    stripped = html_body.strip()
    if stripped.startswith("```"):
        lines = stripped.splitlines()
        if lines and lines[0].startswith("```"):
            lines = lines[1:]
        if lines and lines[-1].strip().startswith("```"):
            lines = lines[:-1]
        html_body = "\n".join(lines)

    if not html_body.strip():
        print("ERROR: 收到空的內文，停止寄送。", file=sys.stderr)
        sys.exit(2)

    today = datetime.date.today().strftime("%Y-%m-%d")
    subject_prefix = sys.argv[1] if len(sys.argv) > 1 else "每日 Java/Spring Boot"
    subject = f"{subject_prefix} — {today}"

    app_password = get_app_password(conf["GMAIL_USER"], conf["KEYCHAIN_SERVICE"])

    msg = MIMEText(html_body, "html", "utf-8")
    msg["Subject"] = subject
    msg["From"] = formataddr(("Java Learn Digest", conf["GMAIL_USER"]))
    msg["To"] = conf["MAIL_TO"]

    try:
        ctx = ssl.create_default_context()
        with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=60) as s:
            s.starttls(context=ctx)
            s.login(conf["GMAIL_USER"], app_password)
            s.send_message(msg)
        print(f"OK: 寄送成功 -> {conf['MAIL_TO']}（主旨：{subject}）")
    except Exception as e:
        print(f"ERROR: 寄送失敗: {e!r}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
