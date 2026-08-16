#!/bin/zsh
# state_synced_with_origin() 的行為測試。
#
# 這個判斷是「斷網時該不該發警示」的唯一依據，兩個方向判錯都會痛：
#   太寬鬆 → 稿其實還沒推上去卻不警示，隔天真的收不到信也沒人知道；
#   太嚴格 → 回到 2026-08-16 19:50 那種誤報（稿 10:17 就備妥也推上去了，
#            只因為那一刻斷網就寄了「明天收不到信」）。
# 所以三種狀態都要釘住。用真的 git repo 測，不 mock——要驗的正是 git 的實際回答。
#
# 跑法：zsh tests/test_sync_guard.sh
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"

fails=0
ok()   { print -r -- "  ok   - $1" }
bad()  { print -r -- "  FAIL - $1"; fails=$((fails+1)) }

TESTROOT="$(mktemp -d -t learn-sync-test)"
trap 'rm -rf "$TESTROOT"' EXIT

# bare remote + 本機 repo，模擬 state worktree 與 origin/state 的關係
git init -q --bare "$TESTROOT/remote.git"
git init -q "$TESTROOT/wt"
git -C "$TESTROOT/wt" config user.email t@example.com
git -C "$TESTROOT/wt" config user.name  tester
mkdir -p "$TESTROOT/wt/state"
print -r -- 'seed' > "$TESTROOT/wt/state/outbox.json"
git -C "$TESTROOT/wt" add -A
git -C "$TESTROOT/wt" commit -qm seed
git -C "$TESTROOT/wt" remote add origin "$TESTROOT/remote.git"
BR="$(git -C "$TESTROOT/wt" symbolic-ref --short HEAD)"
git -C "$TESTROOT/wt" push -q -u origin "$BR"

# 只載入函式，不跑任何班次。
# 兩層防護，因為這裡出過事：2026-08-17 00:10 這支測試 source 下去時 run_learn.sh
# 還沒有 LEARN_LIB_ONLY 閘門，整支腳本跑到底、把當天的信提早八小時寄了出去。
#   第一層：閘門不在就直接放棄，絕不 source。
#   第二層：真的 source 進去也餵一個無效 mode，萬一閘門失效也只會落到 case *) 而不是 daily。
if ! grep -q 'LEARN_LIB_ONLY' "$DIR/run_learn.sh"; then
  print -r -- "FAIL: run_learn.sh 沒有 LEARN_LIB_ONLY 閘門，source 下去會真的寄信——中止測試。"
  exit 1
fi
export STATE_WT="$TESTROOT/wt"
export REPO_SYNC=1
LEARN_LIB_ONLY=1 source "$DIR/run_learn.sh" __lib_only__
LOG="$TESTROOT/run.log"   # 別汙染專案的 run.log

if ! typeset -f state_synced_with_origin >/dev/null; then
  print -r -- "FAIL: run_learn.sh 沒有定義 state_synced_with_origin"
  exit 1
fi

print -r -- "state_synced_with_origin:"

# 1. 乾淨且與 origin 同步 → 已同步（雲端手上有這份庫存，斷網也寄得出去）
if state_synced_with_origin; then ok "乾淨且與 origin 同步 → 判定已同步"
else bad "乾淨且與 origin 同步，卻判成未同步"; fi

# 2. 有未提交的變更 → 未同步（那份內容鐵定還沒送出去）
print -r -- 'dirty' >> "$TESTROOT/wt/state/outbox.json"
if state_synced_with_origin; then bad "有未提交變更，卻判成已同步"
else ok "有未提交變更 → 判定未同步"; fi

# 3. 已 commit 但還沒 push → 未同步（本機領先 origin）
git -C "$TESTROOT/wt" add -A
git -C "$TESTROOT/wt" commit -qm "尚未推上去的變更"
if state_synced_with_origin; then bad "本機領先 origin，卻判成已同步"
else ok "已 commit 但未 push → 判定未同步"; fi

# 4. 推上去之後回到已同步
git -C "$TESTROOT/wt" push -q origin "$BR"
if state_synced_with_origin; then ok "push 之後 → 回到已同步"
else bad "push 之後仍判成未同步"; fi

# 5. 純本機模式（REPO_SYNC=0）沒有雲端可代寄，不該宣稱已同步
REPO_SYNC=0
if state_synced_with_origin; then bad "REPO_SYNC=0 卻判成已同步"
else ok "REPO_SYNC=0 → 判定未同步（沒有雲端可代寄）"; fi
REPO_SYNC=1

# 6. 查不出 upstream（例如剛建的分支）→ 保守判未同步
git -C "$TESTROOT/wt" checkout -q -b 沒有上游的分支
if state_synced_with_origin; then bad "查不出 upstream 卻判成已同步"
else ok "查不出 upstream → 保守判定未同步"; fi

# ── do_prepare 斷網時的處置：什麼時候該閉嘴、什麼時候該叫 ──
# 警示信的成本不對稱：漏叫 = 隔天真的沒信也沒人知道；誤叫 = 半夜被吵醒但其實沒事。
# 兩邊都要釘死，所以三種組合各測一次。對外動作全部換成 stub，不碰真的 git／claude／信箱。
print -r -- ""
print -r -- "do_prepare 斷網時的處置:"

wait_for_network()  { return 0 }
git_pull()          { GITPULL_LAST_ERR="測試用：假裝斷網"; return 1 }
git_push_state()    { return 0 }
notify()            { NOTIFIED=1 }
result()            { RESULT_STATUS="$1"; RESULT_WHY="$2" }
run_claude()        { bad "斷網時不該呼叫 claude 產稿（會疊在過期進度上）"; return 1 }

run_case() {  # $1=outbox_ready 的回傳  $2=state_synced_with_origin 的回傳
  NOTIFIED=0; RESULT_STATUS=""; RESULT_WHY=""
  eval "outbox_ready() { return $1 }"
  eval "state_synced_with_origin() { return $2 }"
  do_prepare; DO_RC=$?
}

# A. 庫存備妥且已同步 → 雲端寄得出去，安靜略過
#    RC=0 這件事本身就是「不發警示」的保證：底下主流程是 [ $RC -ne 0 ] 才叫 send_local_alert。
run_case 0 0
[ "$DO_RC" = 0 ]         && ok "庫存已同步 → 回傳 0（主流程不會發警示）" || bad "庫存已同步卻回傳 $DO_RC，主流程會發警示"
[ "$RESULT_STATUS" = SKIP ] && ok "庫存已同步 → 記 SKIP" || bad "庫存已同步卻記 $RESULT_STATUS"
[ "$NOTIFIED" = 0 ]      && ok "庫存已同步 → 不跳桌面通知" || bad "庫存已同步卻跳了桌面通知"

# B. 庫存備妥但還沒推上去 → 雲端手上沒有，明天真的沒信，要叫
run_case 0 1
[ "$DO_RC" = 1 ]         && ok "庫存未同步 → 回傳 1（主流程會發警示）" || bad "庫存未同步卻回傳 $DO_RC"
[ "$RESULT_STATUS" = FAIL ] && ok "庫存未同步 → 記 FAIL" || bad "庫存未同步卻記 $RESULT_STATUS"
[ "$NOTIFIED" = 1 ]      && ok "庫存未同步 → 跳桌面通知" || bad "庫存未同步卻沒跳桌面通知"

# C. 根本沒庫存 → 就算已同步也代表雲端同樣沒有，明天沒信，要叫
run_case 1 0
[ "$DO_RC" = 1 ]         && ok "沒庫存 → 回傳 1（主流程會發警示）" || bad "沒庫存卻回傳 $DO_RC"
[ "$RESULT_STATUS" = FAIL ] && ok "沒庫存 → 記 FAIL" || bad "沒庫存卻記 $RESULT_STATUS"

# ── do_prepare_batch 斷網時的處置 ──
# batch 不寄警示信（主流程只對 prepare/prepare-weekly 發），但記 FAIL 一樣有代價：
# 那天的 attempts 紀錄會多一筆看起來出事的行，而那份紀錄會原樣貼進警示信給人看。
print -r -- ""
print -r -- "do_prepare_batch 斷網時的處置:"

# 假的 python：只回答 --queue-len，其餘一律失敗（斷網分支不該用到別的）
STUB_PY="$TESTROOT/fake-python"
cat > "$STUB_PY" <<'STUB'
#!/bin/zsh
for a in "$@"; do
  [ "$a" = "--queue-len" ] && { print -r -- "$FAKE_QUEUE_LEN"; exit 0 }
done
exit 1
STUB
chmod +x "$STUB_PY"
PYTHON="$STUB_PY"

run_batch() {  # $1=庫存篇數  $2=目標篇數  $3=state_synced_with_origin 的回傳
  export FAKE_QUEUE_LEN="$1"
  RESULT_STATUS=""; RESULT_WHY=""
  eval "state_synced_with_origin() { return $3 }"
  do_prepare_batch "$2"; DO_RC=$?
}

# 庫存 3 篇、目標 2 篇、已同步 → 本來就沒事做
run_batch 3 2 0
[ "$DO_RC" = 0 ] && [ "$RESULT_STATUS" = SKIP ] \
  && ok "庫存達標且已同步 → SKIP" || bad "庫存達標且已同步卻是 rc=$DO_RC / $RESULT_STATUS"

# 庫存 1 篇、目標 2 篇 → 沒補滿，而斷網又不能產，這是真的沒做到
run_batch 1 2 0
[ "$DO_RC" = 1 ] && [ "$RESULT_STATUS" = FAIL ] \
  && ok "庫存未達標 → FAIL" || bad "庫存未達標卻是 rc=$DO_RC / $RESULT_STATUS"

# 庫存 3 篇但沒推上去 → 雲端手上沒有，數字再漂亮也不算數
run_batch 3 2 1
[ "$DO_RC" = 1 ] && [ "$RESULT_STATUS" = FAIL ] \
  && ok "庫存達標但未同步 → FAIL" || bad "庫存達標但未同步卻是 rc=$DO_RC / $RESULT_STATUS"

print -r -- ""
if [ $fails -eq 0 ]; then
  print -r -- "全部通過"
  exit 0
fi
print -r -- "$fails 項失敗"
exit 1
