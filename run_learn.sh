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
# 網路就緒最多等 90×5=450 秒（7.5 分鐘）。
# 120 秒是照「WiFi 喚醒後慢個幾十秒」設的，對固定 WiFi 夠，對手機熱點遠遠不夠：
# Mac 要先用藍牙把 iPhone 叫醒、iPhone 才開始廣播、再關聯、再 DHCP，整串常要好幾分鐘。
# 7/27 實測：12:00:04 開跑、12:02:01 等滿 120 秒放棄，網路 12:04:09 才通，差 2 分 8 秒。
NET_WAIT_MAX=90

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }
notify() { /usr/bin/osascript -e "display notification \"$2\" with title \"$1\" sound name \"Basso\"" >/dev/null 2>&1; }

# 每個時段留一行結果，方便事後一眼看完當天發生什麼事：
#   2026-07-26 13:00:12 RESULT prepare FAIL 網路未就緒
# 沒有這行就代表「這個時段根本沒被觸發」（機器沒醒），跟「跑了但失敗」是兩回事，
# 混在一起就無從除錯。
result() {  # $1=OK|SKIP|FAIL  $2=說明
  log "RESULT $MODE $1 $2"
}

START_HHMM="$(date +%H%M)"   # 本次啟動時間，用來判斷自己是不是當天最後一個備稿班

# 雲端寄信模式：用 git 當同步通道，但「紀錄」放獨立的 state 分支，
# 透過旁邊的 worktree（預設 ../java-learn-state）讀寫，master 只剩開發、不被每日紀錄洗版。
# prepare 前先 pull 取得雲端推進的進度，備好下一篇後 push 上去給雲端寄。
# REPO_SYNC=0 可關掉（純本機模式）；STATE_WT 可覆寫 worktree 路徑。
REPO_SYNC="${REPO_SYNC:-1}"
STATE_WT="${STATE_WT:-$(dirname "$DIR")/java-learn-state}"
# git 網路操作一律包這個，理由是 2026-08-02/03 連兩天的教訓：
# 憑證助手拿不到 Keychain（errSecInteractionNotAllowed）時不會失敗，而是無限等下去。
# git push 因此永不返回，launchd 同一個 label 前一次還在跑就不會再啟動，
# 一卡就吃掉當天剩下所有班次——08-03 那次從 12:02 卡到 18:00，13:00 那班完全沒跑，
# 稿明明產好了卻留在本機，雲端 14:00 只能寄缺稿警示。
# BatchMode / TERMINAL_PROMPT 讓 git 不要問（要問就直接失敗，交給重試邏輯）；
# watchdog 是保險：就算還是卡住，時限一到強制收掉，至少 log 留下痕跡、班次能往下走。
GIT_NET_TIMEOUT="${GIT_NET_TIMEOUT:-60}"
git_timeout() {
  local pid wd rc
  GIT_TERMINAL_PROMPT=0 \
  GIT_SSH_COMMAND='ssh -o ConnectTimeout=10 -o BatchMode=yes' \
    "$@" >>"$LOG" 2>&1 &
  pid=$!
  # 先收子進程再收自己：git 會生 remote-https / credential 這些孫子，只殺父的話它們會留著。
  ( sleep "$GIT_NET_TIMEOUT"; pkill -9 -P "$pid" 2>/dev/null; kill -9 "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  wd=$!
  wait "$pid"; rc=$?
  kill "$wd" 2>/dev/null
  [ "$rc" -ge 128 ] && log "WARN: git 操作超過 ${GIT_NET_TIMEOUT}s 被強制中止（若不中止會無限等待）。"
  return "$rc"
}

git_pull() {
  [ "$REPO_SYNC" = 1 ] || return 0
  local i=1 out reason
  while [ $i -le 3 ]; do
    # ConnectTimeout=10：連不上（例如 port 22 被擋）10 秒內失敗，不要等到預設逾時。
    # BatchMode/TERMINAL_PROMPT：不准問憑證或 host key，要問就失敗——問了就是卡死。
    if out="$(GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o ConnectTimeout=10 -o BatchMode=yes' git -C "$STATE_WT" pull --rebase --autostash 2>&1)"; then
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
  git_timeout git -C "$STATE_WT" pull --rebase --autostash || true
  local i=1
  while [ $i -le 3 ]; do
    if git_timeout git -C "$STATE_WT" push; then
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
  # 先確認網路就緒再 git_pull：launchd 準點常在睡眠或剛喚醒、網路還沒起來，
  # git_pull 只硬等約 15 秒就放棄，會走不到後面能等 120 秒的 wait_for_network。
  if ! wait_for_network; then
    log "INFO: 網路未就緒，本時段略過備稿（待下次）。"
    PREPARE_WHY="網路未就緒"; result FAIL "$PREPARE_WHY"
    return 1
  fi
  if ! git_pull; then
    log "INFO: git pull 失敗、本機 outbox 不可信，本時段略過（不誤判已備妥，待下次同步後再產）。"
    notify "⚠️ 學習信備稿失敗" "無法連線 GitHub：${GITPULL_LAST_ERR:-詳見 run.log}。明天的課程尚未備妥。"
    PREPARE_WHY="state 分支同步失敗：${GITPULL_LAST_ERR:-詳見 run.log}"; result FAIL "$PREPARE_WHY"
    return 1
  fi
  if "$PYTHON" "$DIR/apply_result.py" --outbox-ready 2>>"$LOG"; then
    log "INFO: outbox 已備妥，略過產生。"
    git_push_state   # 前次 push 若失敗，這裡補推，否則備好的稿永遠到不了雲端。
    result SKIP "outbox 已備妥"
    return 0
  fi
  local ctx
  if ! ctx="$("$PYTHON" "$DIR/build_lesson.py" daily 2>>"$LOG")"; then
    log "WARN: build_lesson.py 失敗、拿不到課程資料，本時段放棄（原因見上方 stderr）。"
    PREPARE_WHY="build_lesson.py 失敗，拿不到課程資料"; result FAIL "$PREPARE_WHY"
    return 1
  fi
  if print -r -- "$ctx" | grep -q '^STATUS: FINISHED'; then
    log "INFO: 課綱已全部完成，無需產生。"
    result SKIP "課綱已全部完成"
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
      result OK "備稿完成（明天要寄的課）"
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
  PREPARE_WHY="claude 連續 $MAX_TRIES 次產生課程失敗：${why:-詳見 run.log}"
  result FAIL "$PREPARE_WHY"
  return 1
}

# ── 批次備稿：一次備 N 篇填滿庫存（出遠門用，見 README「庫存佇列」）──
# 跟 do_prepare 的三個差別：
#   1. 不看 outbox-ready——本來就有庫存也要繼續往後疊，不然一篇都補不進去
#   2. 每產一篇都重算下一篇該教什麼：--queue-tail-state 把現有庫存依序 replay
#      出「全部寄完後」的進度與歷史，寫成暫存 state 餵給 build_lesson.py。
#      不能用 step+1 猜——收尾那篇會換主題、step 歸 1，猜錯整串庫存都寄不出去。
#   3. 只在最後推一次 git：中途每篇都 push 會慢，而且產到一半中斷時
#      本機佇列仍然完整，下次再跑會接著疊上去。
do_prepare_batch() {
  local want="${1:-0}"
  if ! print -r -- "$want" | grep -qE '^[1-9][0-9]*$'; then
    log "ERROR: prepare-batch 要帶正整數篇數，例如 ./run_learn.sh prepare-batch 11"
    return 2
  fi
  if ! wait_for_network; then
    log "INFO: 網路未就緒，批次備稿放棄。"
    PREPARE_WHY="網路未就緒"; result FAIL "$PREPARE_WHY"
    return 1
  fi
  if ! git_pull; then
    log "WARN: git pull 失敗，批次備稿放棄（庫存狀態不可信，硬產會疊在過期進度上）。"
    PREPARE_WHY="state 分支同步失敗：${GITPULL_LAST_ERR:-詳見 run.log}"; result FAIL "$PREPARE_WHY"
    return 1
  fi

  # 庫存第一篇的預計寄出日＝明天（今天早上那篇已經寄掉了）。
  # 只影響補進歷史的日期標記，週報的回顧視窗要靠它才篩得到還沒寄出的那幾篇。
  local first_send tail_dir made=0 i ctx idx step base prompt tmp out attempt crc why=""
  first_send="$(date -v+1d +%F)"
  tail_dir="$(mktemp -d -t java-learn-batch)"
  base="$(cat "$DIR/prompt_daily.txt")"
  tmp="$(mktemp -t java-learn)"
  log "INFO: 批次備稿開始，目標 $want 篇，庫存第一篇預計 $first_send 寄出。"

  for (( i = 1; i <= want; i++ )); do
    if ! "$PYTHON" "$DIR/apply_result.py" --queue-tail-state "$tail_dir" \
           --first-send "$first_send" >>"$LOG" 2>&1; then
      log "WARN: 第 $i 篇算不出庫存尾端進度，停在這裡（已備 $made 篇）。"
      break
    fi
    if ! ctx="$("$PYTHON" "$DIR/build_lesson.py" daily \
                 --progress "$tail_dir/progress.json" \
                 --history "$tail_dir/history.jsonl" 2>>"$LOG")"; then
      log "WARN: 第 $i 篇 build_lesson.py 失敗，停在這裡（已備 $made 篇）。"
      break
    fi
    if print -r -- "$ctx" | grep -q '^STATUS: FINISHED'; then
      log "INFO: 課綱已走完，庫存只能備到 $made 篇。"
      break
    fi
    idx="$("$PYTHON" -c "import json;print(json.load(open('$tail_dir/progress.json'))['current_index'])")"
    step="$("$PYTHON" -c "import json;print(json.load(open('$tail_dir/progress.json'))['step'])")"

    attempt=1
    while [ $attempt -le $MAX_TRIES ]; do
      prompt="$base"$'\n\n=== 今日課程資料 ===\n'"$ctx"
      run_claude "$prompt" "$tmp"; crc=$?
      out="$(cat "$tmp")"
      if [ $crc -eq 0 ] && echo "$out" | "$PYTHON" "$DIR/apply_result.py" \
           --append-outbox --index "$idx" --step "$step" >>"$LOG" 2>&1; then
        made=$((made+1))
        log "INFO: 第 $made/$want 篇備妥（第 $idx 課 step $step）。"
        break
      fi
      why="$(print -r -- "$out" | tr '\n' ' ' | tr -s ' ' | tr -d '"\\' | cut -c1-200)"
      [ -z "$why" ] && why="$(tail -n 3 "$CLAUDE_LAST_ERR" 2>/dev/null | tr '\n' ' ' | tr -s ' ' | tr -d '"\\' | cut -c1-200)"
      [ -z "$why" ] && why="claude 未輸出任何內容。"
      log "WARN: 第 $i 篇第 $attempt/$MAX_TRIES 次失敗（rc=$crc）：$why。30 秒後重試。"
      attempt=$((attempt+1)); [ $attempt -le $MAX_TRIES ] && sleep 30
    done
    if [ $attempt -gt $MAX_TRIES ]; then
      log "WARN: 第 $i 篇連續 $MAX_TRIES 次失敗，停在這裡（已備 $made 篇）。"
      break
    fi
  done

  rm -f "$tmp"; rm -rf "$tail_dir"
  # 產幾篇都要推：即使沒達標，已備好的也該送上雲端，不要留在本機。
  git_push_state
  local total
  total="$("$PYTHON" "$DIR/apply_result.py" --queue-len 2>/dev/null || echo '?')"
  if [ "$made" -eq "$want" ]; then
    log "INFO: 批次備稿完成，本次新增 $made 篇，庫存共 $total 篇。"
    result OK "批次備稿完成（新增 $made 篇，庫存 $total 篇）"
    return 0
  fi
  log "WARN: 批次備稿只完成 $made/$want 篇，庫存共 $total 篇。"
  PREPARE_WHY="批次備稿只完成 $made/$want 篇：${why:-詳見 run.log}"
  result FAIL "$PREPARE_WHY"
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
  # 同 do_prepare：先確認網路就緒再 git_pull，避免喚醒空窗就直接放棄。
  if ! wait_for_network; then
    log "INFO: 網路未就緒，略過週報備稿（待下次）。"
    PREPARE_WHY="網路未就緒"; result FAIL "$PREPARE_WHY"; return 1
  fi
  git_pull
  local out wk ctx
  out="$("$PYTHON" "$DIR/build_lesson.py" weekly 2>>"$LOG")"
  wk="$(print -r -- "$out" | sed -n 's/^WEEK_ID: //p' | head -1)"
  if [ -z "$wk" ]; then
    log "WARN: 取不到 WEEK_ID，略過週報備稿。"
    PREPARE_WHY="build_lesson.py 取不到 WEEK_ID"; result FAIL "$PREPARE_WHY"; return 1
  fi
  ctx="$(print -r -- "$out" | grep -v '^WEEK_ID:')"
  if [ -f "$STATE_DIR/weekly_outbox.html" ] && [ "$(cat "$STATE_DIR/weekly_outbox.week" 2>/dev/null)" = "$wk" ]; then
    log "INFO: 週報已備妥（$wk），略過。"; result SKIP "週報已備妥（$wk）"; return 0
  fi
  if [ -f "$STATE_DIR/weekly-$wk" ]; then
    log "INFO: 週報已寄過（$wk），略過備稿。"; result SKIP "週報已寄過（$wk）"; return 0
  fi
  if ! wait_for_network; then
    PREPARE_WHY="網路中途斷線"; result FAIL "$PREPARE_WHY"; return 1
  fi
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
  if [ -z "$html" ]; then
    log "WARN: 週報備稿產生失敗，待下次補產。"
    PREPARE_WHY="claude 連續 $MAX_TRIES 次產生週報失敗"; result FAIL "$PREPARE_WHY"; return 1
  fi
  print -r -- "$html" > "$STATE_DIR/weekly_outbox.html"
  print -r -- "$wk"   > "$STATE_DIR/weekly_outbox.week"
  git_push_state
  log "INFO: 週報已備稿（$wk），待雲端週六寄出。"
  result OK "週報備稿完成（$wk）"
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

# 最後一班仍然失敗 → 當下直接寄警示信。
# 這裡特別重要：java-learn 備的是「明天的課」，等雲端通知等於事發 25 小時後才知道
# （今天備稿失敗 → 明天早上 08:00 沒信 → 明天 14:00 才發警示），根本來不及補。
# 本機寄不出去（多半是沒網路）就不寫 marker，雲端會補寄，兩層不會重複。
# 順序不可顛倒：一定要「確認寄信成功」才寫 marker，反過來會變成沒信也沒人知道。
send_local_alert() {  # $1=失敗原因
  local why="$1" today attempts body
  today="$(date +%F)"
  attempts="$STATE_DIR/attempts-$today.log"
  # 平常成功的日子不留檔，只有出事這天才把當天各時段的結果送上 state 分支供雲端引用
  grep "^$today .*RESULT " "$LOG" > "$attempts" 2>/dev/null || true
  body="<div style=\"font-family:-apple-system,sans-serif\">
<h3>⚠️ 學習信備稿失敗（$MODE）</h3>
<p>最後一個備稿時段仍然失敗。備的是<b>明天</b>要寄的內容，明天早上 08:00 會收不到信。</p>
<p><b>原因：</b>${why:-詳見 run.log}</p>
<p><b>今天各時段：</b></p>
<pre style=\"background:#f6f7f9;padding:10px;border-radius:6px;font-size:12px\">$(cat "$attempts" 2>/dev/null)</pre>
</div>"
  if print -r -- "$body" | "$PYTHON" "$DIR/send_email.py" "⚠️ 學習信備稿失敗" >>"$LOG" 2>&1; then
    date '+%Y-%m-%d %H:%M:%S' > "$STATE_DIR/alert-$MODE-$today"
    log "INFO: 已從本機寄出警示信並標記 alert-$MODE-$today。"
  else
    log "WARN: 本機警示信寄送失敗，改由雲端補寄。"
  fi
  git_push_state
}

echo "===== $(date '+%Y-%m-%d %H:%M:%S') 開始 [mode=$MODE] =====" >> "$LOG"
RC=0
case "$MODE" in
  prepare)         do_prepare        || RC=$? ;;
  prepare-batch)   do_prepare_batch "${2:-}" || RC=$? ;;
  send)            do_send           || RC=$? ;;
  prepare-weekly)  do_prepare_weekly || RC=$? ;;
  daily)           [ -f "$MARKER_DAILY" ] && { log "SKIP: 今日已寄過。"; } || { do_prepare; do_send; } ;;
  weekly)          do_weekly         || RC=$? ;;
  *)               log "ERROR: 未知 mode：$MODE（可用 prepare|prepare-batch N|send|prepare-weekly|weekly）"; exit 2 ;;
esac

# 只有「最後一個備稿班」失敗才警示——此時今天不會再自動好，通知才代表「該動手了」。
# 判斷用本次啟動時間而非現在時間：12:00 那班若跑很久拖過 13:00，它不該搶著發警示。
case "$MODE" in
  prepare|prepare-weekly)
    if [ $RC -ne 0 ] && [ "$START_HHMM" -ge 1300 ] \
       && [ ! -f "$STATE_DIR/alert-$MODE-$(date +%F)" ]; then
      send_local_alert "${PREPARE_WHY:-詳見 run.log}"
    fi ;;
esac

echo "===== $(date '+%Y-%m-%d %H:%M:%S') 結束 [mode=$MODE, rc=$RC] =====" >> "$LOG"
