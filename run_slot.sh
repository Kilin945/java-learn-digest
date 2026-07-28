#!/bin/zsh
# 一個備稿時段要做的事：每日課程一定備，週報只在週五／週六備。
# 由 launchd 在 12:00 / 13:00 觸發。
#
# 為什麼合成一個 job 而不是 prepare 與 prepare-weekly 各排同一個整點：
#   兩個 job 同時觸發會同時對 ../java-learn-state 這個 worktree 做 git pull，
#   互搶 index.lock，先到的成功、後到的莫名其妙失敗。依序跑就沒有這個問題。
#
# 週報時程：週五備稿 → 週六 08:00 雲端寄出。週六這兩班是補救用，
# 若早上已經寄成，run_learn.sh 會看到 marker 直接跳過。
#
# 觸發來源有兩種：
#   1. launchd StartCalendarInterval — 12:00 / 13:00 兩個固定班
#   2. launchd WatchPaths — 網路設定一變（例如熱點接上）就觸發
#
# 有 (2) 是因為固定班會漏。7/27 那天機器「醒著且有網路」的時間是 12:04–12:29，
# 兩個固定班一個早了 4 分鐘、一個晚了 31 分鐘，都沒踩進那個窗口。
#
# 時間窗比 ai-news 寬很多，因為這裡備的是「明天早上 08:00 要寄的課」，
# 跟今天幾點備完全無關，晚上補到也有效。窗內重複觸發無害：已備妥會秒退。
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"

WINDOW_START=800
WINDOW_END=2300
NOW="$((10#$(date +%H%M)))"   # 10# 強制十進位，免得 0900 這種前導零被當八進位
if [ "$NOW" -lt "$WINDOW_START" ] || [ "$NOW" -gt "$WINDOW_END" ]; then
  # 刻意不寫進 run.log：網路設定一天會變很多次，窗外觸發若每次記一行，
  # 幾百行雜訊會把真正要看的 RESULT 淹掉。改成覆寫一個時間戳檔，
  # 想確認「WatchPaths 到底有沒有在動」時看它就好，檔案不會長大。
  date '+%Y-%m-%d %H:%M:%S 窗外觸發，未動作' > "$DIR/.last-trigger.log"
  exit 0
fi

"$DIR/run_learn.sh" prepare

DOW="$(date +%u)"          # 1=週一 … 5=週五 6=週六 7=週日
if [ "$DOW" = 5 ] || [ "$DOW" = 6 ]; then
  "$DIR/run_learn.sh" prepare-weekly
fi

exit 0
