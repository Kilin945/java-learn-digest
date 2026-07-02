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

# 雲端寄信模式：用 git 當同步通道，但「紀錄」放獨立的 state 分支，
# 透過旁邊的 worktree（預設 ../java-learn-state）讀寫，master 只剩開發、不被每日紀錄洗版。
# prepare 前先 pull 取得雲端推進的進度，備好下一篇後 push 上去給雲端寄。
# REPO_SYNC=0 可關掉（純本機模式）；STATE_WT 可覆寫 worktree 路徑。
REPO_SYNC="${REPO_SYNC:-1}"
STATE_WT="${STATE_WT:-$(dirname "$DIR")/java-learn-state}"
git_pull() {
  [ "$REPO_SYNC" = 1 ] || return 0
  local i=1 out reason
  while [ $i -le 3 ]; do
    # 設定 ConnectTimeout=10：無法連線時（例如 port 22 被防火牆阻擋）於 10 秒內失敗，避免等待至預設逾時。
    if out="$(GIT_SSH_COMMAND='ssh -o ConnectTimeout=10' git -C "$STATE_WT" pull --rebase --autostash 2>&1)"; then
      [ -n "$out" ] && echo "$out" >> "$LOG"
      return 0
    fi
    echo "$out" >> "$LOG"
    # 擷取失敗原因寫入 WARN：優先取網路層訊息（ssh、權限、逾時），其次取 git 的 fatal 或 error，最後取輸出末行。
    reason="$(print -r -- "$out" | grep -iE 'ssh:|Permission denied|timed out|Connection (refused|reset)|Could not resolve' | head -1 | tr -d '"\\' | cut -c1-180)"
    [ -z "$reason" ] && reason="$(print -r -- "$out" | grep -iE 'fatal|error|致命|無法' | tail -1 | tr -d '"\\' | cut -c1-180)"
    [ -z "$reason" ] && reason="$(print -r -- "$out" | tail -1 | cut -c1-180)"
    log "WARN: git pull 第 $i/3 次失敗：${reason:-原因不明}。5 秒後重試。"
    i=$((i+1)); sleep 5
  done
  GITPULL_LAST_ERR="$reason"   # 保留末次失敗原因，供呼叫端通知使用。
  log "WARN: git pull 連續 3 次失敗，本機狀態可能過期。"
  return 1
}
git_push_state() {
  [ "$REPO_SYNC" = 1 ] || return 0
  git -C "$STATE_WT" add -A >>"$LOG" 2>&1 || true
  git -C "$STATE_WT" diff --cached --quiet \
    || git -C "$STATE_WT" commit -m "chore: 本機備妥下一篇 $(date +%F)" >>"$LOG" 2>&1 || true
  # 沒有領先 origin 就不必推；查不出 upstream 時保守視為需要推。
  local ahead
  ahead="$(git -C "$STATE_WT" rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo 1)"
  [ "$ahead" = 0 ] && return 0
  git -C "$STATE_WT" pull --rebase --autostash >>"$LOG" 2>&1 || true
  local i=1
  while [ $i -le 3 ]; do
    if git -C "$STATE_WT" push >>"$LOG" 2>&1; then
      log "INFO: 已推上 origin（第 $i 次嘗試，共 $ahead 個 commit）。"
      return 0
    fi
    log "WARN: git push 第 $i/3 次失敗。"
    i=$((i+1)); [ $i -le 3 ] && sleep 5
  done
  log "WARN: git push 連續 3 次失敗（下次再試）。"
  return 1
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
  # 將 claude 的 stderr 另存一份，供失敗時擷取錯誤原因，內容同時寫入 run.log。
  CLAUDE_LAST_ERR="${TMPDIR:-/tmp}/java-learn-claude-err"
  : > "$CLAUDE_LAST_ERR"
  "$CLAUDE" -p "$prompt" --model "$MODEL" --permission-mode default --output-format text > "$outfile" 2>"$CLAUDE_LAST_ERR" &
  local cpid=$!
  ( sleep "$CLAUDE_TIMEOUT"; kill -TERM "$cpid" 2>/dev/null ) &
  local wpid=$!
  wait "$cpid" 2>/dev/null
  local rc=$?
  kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
  cat "$CLAUDE_LAST_ERR" >> "$LOG"
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
  if ! git_pull; then
    log "INFO: git pull 失敗、本機 outbox 不可信，本時段略過（不誤判已備妥，待下次同步後再產）。"
    notify "⚠️ 學習信備稿失敗" "無法連線 GitHub：${GITPULL_LAST_ERR:-詳見 run.log}。明天的課程尚未備妥。"
    return 1
  fi
  if "$PYTHON" "$DIR/apply_result.py" --outbox-ready 2>>"$LOG"; then
    log "INFO: outbox 已備妥，略過產生。"
    git_push_state   # 前次 push 若失敗，這裡補推，否則備好的稿永遠到不了雲端。
    return 0
  fi
  if ! wait_for_network; then return 1; fi
  local ctx
  if ! ctx="$("$PYTHON" "$DIR/build_lesson.py" daily 2>>"$LOG")"; then
    log "WARN: build_lesson.py 失敗、拿不到課程資料，本時段放棄（原因見上方 stderr）。"
    return 1
  fi
  if print -r -- "$ctx" | grep -q '^STATUS: FINISHED'; then
    log "INFO: 課綱已全部完成，無需產生。"
    return 0
  fi
  local base prompt tmp out attempt=1 why=""
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
    # 失敗原因優先取 claude 的標準輸出，其次取標準錯誤（stderr），兩者皆空則標示無輸出。
    why="$(print -r -- "$out" | tr '\n' ' ' | tr -s ' ' | tr -d '"\\' | cut -c1-200)"
    [ -z "$why" ] && why="$(tail -n 3 "$CLAUDE_LAST_ERR" 2>/dev/null | tr '\n' ' ' | tr -s ' ' | tr -d '"\\' | cut -c1-200)"
    [ -z "$why" ] && why="claude 未輸出任何內容。"
    log "WARN: 第 $attempt/$MAX_TRIES 次產生失敗（rc=$crc）：$why。30 秒後重試。"
    attempt=$((attempt+1)); [ $attempt -le $MAX_TRIES ] && sleep 30
  done
  rm -f "$tmp"
  log "WARN: 產生 outbox 失敗，待下次補產（不影響已備妥的內容）。"
  notify "⚠️ 學習信備稿失敗" "claude 連續 $MAX_TRIES 次產生課程失敗：${why:-詳見 run.log}。明天的課程尚未備妥。"
  return 1
}

# ── 快：把 outbox 備妥的內容寄出 ──
do_send() {
  [ -f "$MARKER_DAILY" ] && { log "SKIP: 今日已寄過（$(basename "$MARKER_DAILY")）。"; return 0; }
  if ! wait_for_network; then return 1; fi

  if "$PYTHON" "$DIR/apply_result.py" --outbox-ready 2>>"$LOG"; then
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

# ── 每週回顧：備稿（產好存進 weekly outbox，給雲端週六寄）──
# 跟每日信同理：產生靠本機 claude、寄出靠雲端，週報不再依賴週末筆電醒著。
# 回顧範圍與週身分證（WEEK_ID）由 build_lesson.py 釘在「最近的週五」，晚產也不位移。
do_prepare_weekly() {
  git_pull
  local out wk ctx
  out="$("$PYTHON" "$DIR/build_lesson.py" weekly 2>>"$LOG")"
  wk="$(print -r -- "$out" | sed -n 's/^WEEK_ID: //p' | head -1)"
  [ -z "$wk" ] && { log "WARN: 取不到 WEEK_ID，略過週報備稿。"; return 1; }
  ctx="$(print -r -- "$out" | grep -v '^WEEK_ID:')"
  if [ -f "$STATE_DIR/weekly_outbox.html" ] && [ "$(cat "$STATE_DIR/weekly_outbox.week" 2>/dev/null)" = "$wk" ]; then
    log "INFO: 週報已備妥（$wk），略過。"; return 0
  fi
  [ -f "$STATE_DIR/weekly-$wk" ] && { log "INFO: 週報已寄過（$wk），略過備稿。"; return 0; }
  if ! wait_for_network; then return 1; fi
  local base prompt tmp cout attempt=1 html=""
  base="$(cat "$DIR/prompt_weekly.txt")"
  tmp="$(mktemp -t java-learn)"
  while [ $attempt -le $MAX_TRIES ]; do
    prompt="$base"$'\n\n=== 本週課程資料 ===\n'"$ctx"
    run_claude "$prompt" "$tmp"; local crc=$?
    cout="$(cat "$tmp")"
    if [ $crc -eq 0 ] && looks_like_html "$cout"; then html="$cout"; break; fi
    log "WARN: 第 $attempt/$MAX_TRIES 次週報備稿失敗 (rc=$crc)，30s 後重試。"
    attempt=$((attempt+1)); [ $attempt -le $MAX_TRIES ] && sleep 30
  done
  rm -f "$tmp"
  [ -z "$html" ] && { log "WARN: 週報備稿產生失敗，待下次補產。"; return 1; }
  print -r -- "$html" > "$STATE_DIR/weekly_outbox.html"
  print -r -- "$wk"   > "$STATE_DIR/weekly_outbox.week"
  git_push_state
  log "INFO: 週報已備稿（$wk），待雲端週六寄出。"
}

# ── 每週回顧：即時產生即時寄（不經 outbox、不動進度）。手動 / 備援用 ──
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
  prepare)         do_prepare ;;
  send)            do_send ;;
  prepare-weekly)  do_prepare_weekly ;;
  daily)           [ -f "$MARKER_DAILY" ] && { log "SKIP: 今日已寄過。"; } || { do_prepare; do_send; } ;;
  weekly)          do_weekly ;;
  *)               log "ERROR: 未知 mode：$MODE（可用 prepare|send|prepare-weekly|weekly）"; exit 2 ;;
esac
echo "===== $(date '+%Y-%m-%d %H:%M:%S') 結束 [mode=$MODE] =====" >> "$LOG"
