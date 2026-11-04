#!/bin/bash
# MogoPrint.app 빌드 스크립트. Xcode(또는 Command Line Tools)만 있으면 된다.
set -euo pipefail
cd "$(dirname "$0")"

OUT=build
APP="$OUT/MogoPrint.app"
TGT="-target $(uname -m)-apple-macosx14.0"
mkdir -p "$OUT"

echo "▸ core"
swiftc $TGT -O -parse-as-library -module-name MogoCore \
  -emit-library -static -emit-module -emit-module-path "$OUT/MogoCore.swiftmodule" \
  Sources/MogoCore/*.swift -o "$OUT/libMogoCore.a"

echo "▸ app"
swiftc $TGT -O -parse-as-library -module-name MogoPrint -I "$OUT" -L "$OUT" -lMogoCore \
  Sources/MogoPrint/*.swift -o "$OUT/MogoPrint"

echo "▸ cli"
swiftc $TGT -O -module-name mogo_cli -I "$OUT" -L "$OUT" -lMogoCore \
  Sources/mogo-cli/main.swift -o "$OUT/mogo-cli"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/MogoPrint" "$APP/Contents/MacOS/MogoPrint"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# 명령줄 도구도 앱 안에 같이 넣는다 (터미널에서 쓰려면 README의 링크 만들기 참고).
cp "$OUT/mogo-cli" "$APP/Contents/MacOS/mogo-cli"
codesign --force --sign - "$APP/Contents/MacOS/mogo-cli" >/dev/null
codesign --force --sign - "$APP" >/dev/null

echo "✓ $APP"
echo "  실행: open $APP"
