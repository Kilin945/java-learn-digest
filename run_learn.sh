#!/bin/zsh
# 學習信寄送：由 launchd 觸發，可共用每日/每週。
# 用法：run_learn.sh [kind] [prompt檔] [主旨前綴]
#   kind = daily(預設) | weekly
# 可靠性：每週期只成功寄一次（state/ 下的 marker 去重）；失敗只記 log、不寄垃圾、待補跑。

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$DIR/run.log"
STATE_DIR="$DIR/state"
mkdir -p "$STATE_DIR"

if [ ! -f "$DIR/config.env" ]; then
  echo "ERROR: 找不到 $DIR/config.env，請先 cp config.env.example config.env 並填入設定。" >> "$LOG"
  exit 5
fi
source "$DIR/config.env"
export GMAIL_USER MAIL_TO KEYCHAIN_SERVICE LEARN_GOAL

CLAUDE="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
PYTHON="${PYTHON_BIN:-/opt/homebrew/bin/python3}"
MODEL="${CLAUDE_MODEL:-sonnet}"

KIND="${1:-daily}"
if [ "$KIND" = "weekly" ]; then
  PROMPT_FILE="${2:-prompt_weekly.txt}"
  SUBJECT_PREFIX="${3:-每週 Java/Spring Boot 回顧}"
else
  PROMPT_FILE="${2:-prompt_daily.txt}"
  SUBJECT_PREFIX="${3:-每日 Java/Spring Boot}"
fi

MAX_TRIES=3
CLAUDE_TIMEOUT=600
NET_WAIT_MAX=24

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }
notify() { /usr/bin/osascript -e "display notification \"$2\" with title \"$1\" sound name \"Basso\"" >/dev/null 2>&1; }

period_key() { [ "$KIND" = "weekly" ] && date +%G-W%V || date +%F; }
MARKER="$STATE_DIR/${KIND}-$(period_key)"

if [ -f "$MARKER" ]; then
  log "SKIP: [$SUBJECT_PREFIX] 本週期已寄過（$(basename "$MARKER")），跳過。"
  exit 0
fi

wait_for_network() {
  local i=0
  until curl -sf --max-time 5 https://www.google.com/generate_204 >/dev/null 2>&1; do
    i=$((i+1))
    if [ $i -ge $NET_WAIT_MAX ]; then
      log "WARN: 網路在 $((NET_WAIT_MAX*5))s 內未就緒，本時段放棄。"
      return 1
    fi
    sleep 5
  done
  return 0
}

run_claude() {  # $1=prompt 字串 $2=輸出檔
  local prompt="$1" outfile="$2"
  : > "$outfile"
  "$CLAUDE" -p "$prompt" --model "$MODEL" --permission-mode default --output-format text > "$outfile" 2>>"$LOG" &
  local cpid=$!
  ( sleep "$CLAUDE_TIMEOUT"; kill -TERM "$cpid" 2>/dev/null ) &
  local wpid=$!
  wait "$cpid" 2>/dev/null
  local rc=$?
  kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
  return $rc
}

looks_like_html() {  # 給每週用：像 HTML 且不含錯誤字樣
  local out="$1"
  [ -n "$out" ] || return 1
  print -r -- "$out" | grep -q '<' || return 1
  print -r -- "$out" | grep -qiE 'API Error|socket connection|^Error:' && return 1
  return 0
}

echo "===== $(date '+%Y-%m-%d %H:%M:%S') 開始 [$SUBJECT_PREFIX] (kind=$KIND) =====" >> "$LOG"
BASE_PROMPT="$(cat "$DIR/$PROMPT_FILE")"

# ── 組 context（每日可能回報 FINISHED）──
if ! wait_for_network; then
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') 結束 (網路未就緒待補跑) =====" >> "$LOG"; exit 1
fi
CTX="$("$PYTHON" "$DIR/build_lesson.py" "$KIND" 2>>"$LOG")"

if [ "$KIND" = "daily" ] && print -r -- "$CTX" | grep -q '^STATUS: FINISHED'; then
  DONE_HTML='<div style="font-family:-apple-system,sans-serif;max-width:680px;margin:0 auto;color:#16213e;"><div style="font-size:20px;font-weight:800;">🎉 你已完成整份課綱！</div><p style="font-size:14px;line-height:1.7;color:#3b424f;">恭喜走完所有主題。可以編輯 syllabus.txt 加新主題，或開始循環複習。</p></div>'
  SEND_OUT="$(echo "$DONE_HTML" | "$PYTHON" "$DIR/send_email.py" "Java/Spring Boot 課綱完成" 2>&1)"; RC=$?
  echo "$SEND_OUT" >> "$LOG"
  [ $RC -eq 0 ] && date '+%Y-%m-%d %H:%M:%S' > "$MARKER" && log "INFO: 課綱已完成，寄出完成通知。"
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') 結束 (rc=$RC, 課綱完成) =====" >> "$LOG"; exit $RC
fi

# ── 呼叫 claude（重試）──
TMP_OUT="$(mktemp -t java-learn)"
RAW=""
attempt=1
while [ $attempt -le $MAX_TRIES ]; do
  PROMPT="$BASE_PROMPT"$'\n\n=== 今日課程資料 ===\n'"$CTX"
  run_claude "$PROMPT" "$TMP_OUT"; crc=$?
  OUT="$(cat "$TMP_OUT")"
  if [ "$KIND" = "daily" ]; then
    # 每日：用 apply_result 驗證模式解析出 html（不動狀態）
    if [ $crc -eq 0 ] && HTML="$(echo "$OUT" | "$PYTHON" "$DIR/apply_result.py" 2>>"$LOG")" && [ -n "$HTML" ]; then
      RAW="$OUT"; log "INFO: 第 $attempt 次成功解析。"; break
    fi
  else
    if [ $crc -eq 0 ] && looks_like_html "$OUT"; then
      HTML="$OUT"; RAW="$OUT"; log "INFO: 第 $attempt 次成功。"; break
    fi
  fi
  log "WARN: 第 $attempt/$MAX_TRIES 次失敗 (rc=$crc, 長度=${#OUT})，30s 後重試。"
  attempt=$((attempt+1)); [ $attempt -le $MAX_TRIES ] && sleep 30
done
rm -f "$TMP_OUT"

if [ -z "$RAW" ]; then
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') 結束 (rc=1, 失敗待補跑) =====" >> "$LOG"; exit 1
fi

# ── 寄信 ──
SEND_OUT="$(echo "$HTML" | "$PYTHON" "$DIR/send_email.py" "$SUBJECT_PREFIX" 2>&1)"; RC=$?
echo "$SEND_OUT" >> "$LOG"
if [ $RC -eq 0 ]; then
  date '+%Y-%m-%d %H:%M:%S' > "$MARKER"
  if [ "$KIND" = "daily" ]; then
    # 寄成功才推進度＋寫存檔（把同一份 claude 輸出餵 --commit）
    if ! echo "$RAW" | "$PYTHON" "$DIR/apply_result.py" --commit >>"$LOG" 2>&1; then
      log "WARN: 進度更新失敗（信已寄出，明天可能重複同一步）。"
    fi
  fi
  log "INFO: 已寄出並標記 $(basename "$MARKER")。"
else
  REASON="$(echo "$SEND_OUT" | grep -iE 'error' | tail -1 | tr -d '"\\' | cut -c1-180)"
  [ -z "$REASON" ] && REASON="請查看 run.log"
  notify "⚠️ 學習信寄送失敗" "$SUBJECT_PREFIX：$REASON"
  log "NOTIFY: 寄送失敗。原因：$REASON"
fi
echo "===== $(date '+%Y-%m-%d %H:%M:%S') 結束 (rc=$RC) =====" >> "$LOG"
exit $RC
