#!/bin/bash
# Phát hành Messenger Vdk một lệnh: bash phat-hanh/phat-hanh.sh <bản, vd 0.6.1> [--github]
#  1. Build 2 bản: ký chứng chỉ máy anh (cài máy anh / lưu T7) + ký tạm ad-hoc (đăng GitHub – không lộ email Apple ID)
#  2. Zip sạch (không file ._), ký zip GitHub bằng khoá cập nhật trong Keychain (app kiểm chữ ký này trước khi tự cài)
#  3. DMG có ảnh nền cho cả 2 bản (cần DMG_PY = python có dmgbuild)
#  4. Chép bản ký riêng lên Ban build/;  --github: tạo Release v<bản> (zip + zip.sig + dmg), ghi chú lấy từ phat-hanh/ghi-chu-<bản>.md
set -eu
BAN="$1"; GOC="$(cd "$(dirname "$0")/.." && pwd)"; cd "$GOC"
[ "$(defaults read "$GOC/Ma nguon/Info.plist" CFBundleShortVersionString)" = "$BAN" ] || { echo "⛔ Info.plist chưa phải bản $BAN"; exit 1; }
R="${TMPDIR:-/tmp}/messenger-vdk-phat-hanh-$BAN"; rm -rf "$R"; mkdir -p "$R/rieng" "$R/github"
bash build.sh "$R/rieng" | tail -3
KY_APP=- bash build.sh "$R/github" | tail -3
TEN="Messenger Vdk"
for n in rieng github; do
  (cd "$R/$n" && ditto -c -k --norsrc --noextattr --keepParent "$TEN.app" "$TEN $BAN.zip")
  bash dmg/tao-dmg.sh "$R/$n/$TEN.app" "$R/$n/$TEN $BAN.dmg" | tail -1
done
swift phat-hanh/khoa.swift ky "$R/github/$TEN $BAN.zip"
swift phat-hanh/khoa.swift kiem "$R/github/$TEN $BAN.zip"
B="$GOC/Ban build"; rm -rf "$B/$TEN.app"
ditto "$R/rieng/$TEN.app" "$B/$TEN.app"; cp "$R/rieng/$TEN $BAN.zip" "$R/rieng/$TEN $BAN.dmg" "$B/"
echo "→ T7 Ban build: $TEN.app + zip + dmg ($BAN)"
if [ "${2:-}" = "--github" ]; then
  GHI="$GOC/phat-hanh/ghi-chu-$BAN.md"; [ -f "$GHI" ] || { echo "⛔ thiếu $GHI"; exit 1; }
  # GitHub đổi dấu cách trong tên file thành dấu chấm → đặt sẵn tên có dấu chấm để zip.sig khớp tên zip
  Z="$R/github/Messenger.Vdk.$BAN.zip"; mv "$R/github/$TEN $BAN.zip" "$Z"; mv "$R/github/$TEN $BAN.zip.sig" "$Z.sig"
  D="$R/github/Messenger.Vdk.$BAN.dmg"; mv "$R/github/$TEN $BAN.dmg" "$D"
  gh release create "v$BAN" "$D" "$Z" "$Z.sig" --title "$TEN $BAN" --notes-file "$GHI"
fi
echo "✅ xong – thư mục build: $R"
