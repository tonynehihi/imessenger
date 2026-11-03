#!/bin/bash
# Build Messenger Vdk (trước: Vduck Messenger) – chỉ arm64, ký bằng chứng chỉ Apple Development.
# Cách dùng: bash build.sh [thư_mục_build]   (mặc định: $TMPDIR/vduck-messenger-build)
set -u
GOC="$(cd "$(dirname "$0")" && pwd)/Ma nguon"
B="${1:-${TMPDIR:-/tmp}/vduck-messenger-build}"
APP="$B/Messenger Vdk.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -target arm64-apple-macos14.0 "$GOC/main.swift" -o "$APP/Contents/MacOS/Messenger" 2>"$B/build.log"
ec=$?
if [ $ec -ne 0 ] || grep -q "error:" "$B/build.log"; then
  echo "⛔ build lỗi (exit $ec):"; cat "$B/build.log"; exit 1
fi

cp "$GOC/Info.plist" "$APP/Contents/Info.plist"
cp "$GOC/icon.icns" "$APP/Contents/Resources/icon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Chứng chỉ ký: biến KY_APP, hoặc file .ky-app cạnh build.sh (không đưa lên GitHub); không có → ký tạm (ad-hoc "-")
KY="${KY_APP:-$(cat "$(dirname "$0")/.ky-app" 2>/dev/null)}"; KY="${KY:--}"
codesign -s "$KY" --force --options runtime --entitlements "$GOC/entitlements.plist" "$APP" \
  || { echo "⛔ ký app lỗi (chứng chỉ Apple Development hết hạn / bị xoá?)"; exit 1; }

echo "✅ $APP"
lipo -archs "$APP/Contents/MacOS/Messenger"
du -sh "$APP" | cut -f1
