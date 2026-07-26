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
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"

"$DIR/run_learn.sh" prepare

DOW="$(date +%u)"          # 1=週一 … 5=週五 6=週六 7=週日
if [ "$DOW" = 5 ] || [ "$DOW" = 6 ]; then
  "$DIR/run_learn.sh" prepare-weekly
fi

exit 0
