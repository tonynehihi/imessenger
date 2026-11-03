#!/bin/bash
# Tạo DMG đẹp cho Messenger Vdk: ảnh nền + mũi tên, icon ổ đĩa, sắp sẵn app / Applications / hướng dẫn mở lần đầu.
# Cách dùng: bash dmg/tao-dmg.sh "<đường dẫn Messenger Vdk.app>" "<file .dmg ra>"
# Cần dmgbuild: máy anh cài sẵn ở ~/.venvs/dmgbuild (tự dùng); máy khác: pip install dmgbuild hoặc đặt DMG_PY.
set -eu
APP="$1"; RA="$2"; GOC="$(cd "$(dirname "$0")/.." && pwd)"; PY="${DMG_PY:-$([ -x "$HOME/.venvs/dmgbuild/bin/python3" ] && echo "$HOME/.venvs/dmgbuild/bin/python3" || echo python3)}"
"$PY" -c "import dmgbuild" 2>/dev/null || { echo "⛔ thiếu dmgbuild: pip install dmgbuild (hoặc đặt DMG_PY)"; exit 1; }
TAM="$(mktemp -d)"
python3 "$GOC/dmg/md-sang-html.py" "$GOC/HUONG-DAN-CAI.md" "$TAM/Hướng dẫn mở lần đầu.html" >/dev/null
swift "$GOC/dmg/ve-nen.swift" "$TAM"
tiffutil -cathidpicheck "$TAM/nen.png" "$TAM/nen@2x.png" -out "$TAM/nen.tiff" >/dev/null 2>&1
rm -f "$RA"
"$PY" -m dmgbuild -s "$GOC/dmg/cai-dat-dmg.py" -D app="$APP" -D huongdan="$TAM/Hướng dẫn mở lần đầu.html" \
  -D nen="$TAM/nen.tiff" -D icon="$GOC/Ma nguon/icon.icns" "Messenger Vdk" "$RA"
rm -rf "$TAM"; echo "✅ $RA"
