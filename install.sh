#!/bin/zsh
# 安裝器：把 launchd 範本中的 __PROJECT_DIR__ 換成本專案絕對路徑，載入排程。
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
LA="$HOME/Library/LaunchAgents"
mkdir -p "$LA"

if [ ! -f "$DIR/config.env" ]; then
  echo "請先建立 config.env：cp config.env.example config.env 後填入設定。"
  exit 1
fi

for tmpl in "$DIR"/launchd/*.plist.template; do
  name="$(basename "${tmpl%.template}")"
  dest="$LA/$name"
  sed "s|__PROJECT_DIR__|$DIR|g" "$tmpl" > "$dest"
  launchctl unload "$dest" 2>/dev/null || true
  launchctl load "$dest"
  echo "已安裝排程：$name"
done

echo
echo "提醒：請先把 Gmail App Password 存進 Keychain（只需一次）："
echo "  security add-generic-password -a \"\$GMAIL_USER\" -s \"java-learn-gmail\" -w"
echo "立即測試：zsh $DIR/run_learn.sh daily"
