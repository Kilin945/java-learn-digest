#!/bin/zsh
# 學習信：產生(prepare) 與 寄出(send) 解耦，讓寄出能塞進闔蓋喚醒的數十秒時間窗。
# 用法：run_learn.sh [mode]
#   prepare  慢：若 outbox 未備妥，用 claude 產好「下一篇」存進 outbox（無時間壓力、無 marker）
#   send     快：marker 未命中且 outbox 備妥 → 寄出 → 成功才推進度＋清 outbox＋打 marker
#   daily    一次做完：prepare 再 send（手動測試／舊排程相容用）
#   weekly   每週回顧（即時產生即時寄，不經 outbox、不動進度）
# 可靠性：每週期只成功寄一次（marker 去重）；失敗只記 log、不寄垃圾、待補跑。

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

MODE="${1:-daily}"
SUBJECT_DAILY="每日 Java/Spring Boot"
SUBJECT_WEEKLY="每週 Java/Spring Boot 回顧"

MAX_TRIES=3
CLAUDE_TIMEOUT=600
NET_WAIT_MAX=24

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }
notify() { /usr/bin/osascript -e "display notification \"$2\" with title \"$1\" sound name \"Basso\"" >/dev/null 2>&1; }

# 雲端寄信模式：用 git 當同步通道。prepare 前先 pull 取得雲端推進的進度，
# 備好下一篇後 push 上去給雲端寄。REPO_SYNC=0 可關掉（純本機模式）。
REPO_SYNC="${REPO_SYNC:-1}"
git_pull() {
  [ "$REPO_SYNC" = 1 ] || return 0
  git -C "$DIR" pull --rebase --autostash >>"$LOG" 2>&1 || log "WARN: git pull 失敗（用本機現況續跑）。"
}
git_push_state() {
  [ "$REPO_SYNC" = 1 ] || return 0
  git -C "$DIR" add state lessons >>"$LOG" 2>&1 || true
  git -C "$DIR" diff --cached --quiet && return 0
  git -C "$DIR" commit -m "chore: 本機備妥下一篇 $(date +%F)" >>"$LOG" 2>&1 || true
  git -C "$DIR" pull --rebase --autostash >>"$LOG" 2>&1 || true
  git -C "$DIR" push >>"$LOG" 2>&1 || log "WARN: git push 失敗（下次再試）。"
}

MARKER_DAILY="$STATE_DIR/daily-$(date +%F)"
MARKER_WEEKLY="$STATE_DIR/weekly-$(date +%G-W%V)"

DONE_HTML='<div style="font-family:-apple-system,sans-serif;max-width:680px;margin:0 auto;color:#16213e;"><div style="font-size:20px;font-weight:800;">🎉 你已完成整份課綱！</div><p style="font-size:14px;line-height:1.7;color:#3b424f;">恭喜走完所有主題。可以編輯 syllabus.txt 加新主題，或開始循環複習。</p></div>'

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

send_html() {  # $1=html $2=主旨前綴 ；回傳寄信 rc
  local html="$1" subject="$2"
  local out rc
  out="$(echo "$html" | "$PYTHON" "$DIR/send_email.py" "$subject" 2>&1)"; rc=$?
  echo "$out" >> "$LOG"
  if [ $rc -ne 0 ]; then
    local reason="$(echo "$out" | grep -iE 'error' | tail -1 | tr -d '"\\' | cut -c1-180)"
    [ -z "$reason" ] && reason="請查看 run.log"
    notify "⚠️ 學習信寄送失敗" "$subject：$reason"
    log "NOTIFY: 寄送失敗。原因：$reason"
  fi
  return $rc
}

# ── 慢：產好「下一篇」存進 outbox ──
do_prepare() {
  git_pull   # 先同步雲端寄出後推進的進度，避免重複備同一篇
  if "$PYTHON" "$DIR/apply_result.py" --outbox-ready 2>/dev/null; then
    log "INFO: outbox 已備妥，略過產生。"
    return 0
  fi
  if ! wait_for_network; then return 1; fi
  local ctx
  ctx="$("$PYTHON" "$DIR/build_lesson.py" daily 2>>"$LOG")"
  if print -r -- "$ctx" | grep -q '^STATUS: FINISHED'; then
    log "INFO: 課綱已全部完成，無需產生。"
    return 0
  fi
  local base prompt tmp out attempt=1
  base="$(cat "$DIR/prompt_daily.txt")"
  tmp="$(mktemp -t java-learn)"
  while [ $attempt -le $MAX_TRIES ]; do
    prompt="$base"$'\n\n=== 今日課程資料 ===\n'"$ctx"
    run_claude "$prompt" "$tmp"; local crc=$?
    out="$(cat "$tmp")"
    if [ $crc -eq 0 ] && echo "$out" | "$PYTHON" "$DIR/apply_result.py" --to-outbox >>"$LOG" 2>&1; then
      log "INFO: 第 $attempt 次產生並存進 outbox 成功。"
      git_push_state   # 把備好的 outbox 推給雲端寄出
      rm -f "$tmp"; return 0
    fi
    log "WARN: 第 $attempt/$MAX_TRIES 次產生失敗 (rc=$crc, 長度=${#out})，30s 後重試。"
    attempt=$((attempt+1)); [ $attempt -le $MAX_TRIES ] && sleep 30
  done
  rm -f "$tmp"
  log "WARN: 產生 outbox 失敗，待下次補產（不影響已備妥的內容）。"
  return 1
}

# ── 快：把 outbox 備妥的內容寄出 ──
do_send() {
  [ -f "$MARKER_DAILY" ] && { log "SKIP: 今日已寄過（$(basename "$MARKER_DAILY")）。"; return 0; }
  if ! wait_for_network; then return 1; fi

  if "$PYTHON" "$DIR/apply_result.py" --outbox-ready 2>/dev/null; then
    local html
    html="$("$PYTHON" "$DIR/apply_result.py" --outbox-html 2>>"$LOG")"
    if send_html "$html" "$SUBJECT_DAILY"; then
      "$PYTHON" "$DIR/apply_result.py" --commit-outbox >>"$LOG" 2>&1 \
        || log "WARN: outbox 推進度失敗（信已寄出）。"
      date '+%Y-%m-%d %H:%M:%S' > "$MARKER_DAILY"
      log "INFO: 已寄出備妥內容、推進度並標記 $(basename "$MARKER_DAILY")。"
      # commit 後 lessons/<today>.md 已寫好 → 同步成 Notion 子頁（去重、失敗不影響信）
      _today="$(date +%F)"
      if "$PYTHON" "$DIR/sync_notion.py" --md "$DIR/lessons/$_today.md" --date "$_today" >>"$LOG" 2>&1; then
        log "INFO: 已同步 $_today 到 Notion。"
      else
        log "WARN: Notion 同步失敗（信已寄出、進度已推），可稍後手動補：python3 sync_notion.py --md lessons/$_today.md --date $_today"
      fi
    fi
    return 0
  fi

  # outbox 未備妥：若課綱已完成 → 寄完成通知；否則先略過待 prepare 補上
  local ctx
  ctx="$("$PYTHON" "$DIR/build_lesson.py" daily 2>>"$LOG")"
  if print -r -- "$ctx" | grep -q '^STATUS: FINISHED'; then
    if send_html "$DONE_HTML" "Java/Spring Boot 課綱完成"; then
      date '+%Y-%m-%d %H:%M:%S' > "$MARKER_DAILY"
      log "INFO: 課綱已完成，寄出完成通知並標記。"
    fi
  else
    log "INFO: outbox 尚未備妥，本時段先略過（待 prepare 補上後的時段再寄）。"
  fi
}

# ── 每週回顧：即時產生即時寄（不經 outbox、不動進度）──
do_weekly() {
  [ -f "$MARKER_WEEKLY" ] && { log "SKIP: 本週已寄過（$(basename "$MARKER_WEEKLY")）。"; return 0; }
  if ! wait_for_network; then return 1; fi
  local ctx base prompt tmp out attempt=1 html=""
  ctx="$("$PYTHON" "$DIR/build_lesson.py" weekly 2>>"$LOG")"
  base="$(cat "$DIR/prompt_weekly.txt")"
  tmp="$(mktemp -t java-learn)"
  while [ $attempt -le $MAX_TRIES ]; do
    prompt="$base"$'\n\n=== 本週課程資料 ===\n'"$ctx"
    run_claude "$prompt" "$tmp"; local crc=$?
    out="$(cat "$tmp")"
    if [ $crc -eq 0 ] && looks_like_html "$out"; then html="$out"; break; fi
    log "WARN: 第 $attempt/$MAX_TRIES 次每週產生失敗 (rc=$crc)，30s 後重試。"
    attempt=$((attempt+1)); [ $attempt -le $MAX_TRIES ] && sleep 30
  done
  rm -f "$tmp"
  [ -z "$html" ] && { log "WARN: 每週內容產生失敗，待補跑。"; return 1; }
  if send_html "$html" "$SUBJECT_WEEKLY"; then
    date '+%Y-%m-%d %H:%M:%S' > "$MARKER_WEEKLY"
    log "INFO: 已寄出每週回顧並標記。"
  fi
}

echo "===== $(date '+%Y-%m-%d %H:%M:%S') 開始 [mode=$MODE] =====" >> "$LOG"
case "$MODE" in
  prepare) do_prepare ;;
  send)    do_send ;;
  daily)   [ -f "$MARKER_DAILY" ] && { log "SKIP: 今日已寄過。"; } || { do_prepare; do_send; } ;;
  weekly)  do_weekly ;;
  *)       log "ERROR: 未知 mode：$MODE（可用 prepare|send|daily|weekly）"; exit 2 ;;
esac
echo "===== $(date '+%Y-%m-%d %H:%M:%S') 結束 [mode=$MODE] =====" >> "$LOG"
