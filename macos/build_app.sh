#!/bin/bash
# MogoPrint.app 빌드 스크립트. Xcode(또는 Command Line Tools)만 있으면 된다.
#   bash build_app.sh                      # 이 맥의 CPU용(개발용, 임시 서명)
#   ARCHS="arm64 x86_64" bash build_app.sh # Apple Silicon·Intel 겸용(배포용은 release.sh가 이렇게 부른다)
set -euo pipefail
cd "$(dirname "$0")"

OUT=build
APP="$OUT/MogoPrint.app"
ARCHS="${ARCHS:-$(uname -m)}"
mkdir -p "$OUT"

APP_BINS=()
CLI_BINS=()
for ARCH in $ARCHS; do
  O="$OUT/$ARCH"
  TGT="-target $ARCH-apple-macosx14.0"
  mkdir -p "$O"
  echo "▸ $ARCH: core"
  swiftc $TGT -O -parse-as-library -module-name MogoCore \
    -emit-library -static -emit-module -emit-module-path "$O/MogoCore.swiftmodule" \
    Sources/MogoCore/*.swift -o "$O/libMogoCore.a"
  echo "▸ $ARCH: app"
  swiftc $TGT -O -parse-as-library -module-name MogoPrint -I "$O" -L "$O" -lMogoCore \
    Sources/MogoPrint/*.swift -o "$O/MogoPrint"
  echo "▸ $ARCH: cli"
  swiftc $TGT -O -module-name mogo_cli -I "$O" -L "$O" -lMogoCore \
    Sources/mogo-cli/main.swift -o "$O/mogo-cli"
  APP_BINS+=("$O/MogoPrint")
  CLI_BINS+=("$O/mogo-cli")
done

# CPU별 실행 파일을 하나로 합친다(하나뿐이면 그대로).
lipo -create "${APP_BINS[@]}" -output "$OUT/MogoPrint"
lipo -create "${CLI_BINS[@]}" -output "$OUT/mogo-cli"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/MogoPrint" "$APP/Contents/MacOS/MogoPrint"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# 명령줄 도구도 앱 안에 같이 넣는다 (터미널에서 쓰려면 README의 링크 만들기 참고).
cp "$OUT/mogo-cli" "$APP/Contents/MacOS/mogo-cli"
# 개발용 임시 서명. 배포용 서명(Developer ID)은 release.sh가 다시 한다.
codesign --force --sign - "$APP/Contents/MacOS/mogo-cli" >/dev/null
codesign --force --sign - "$APP" >/dev/null

echo "✓ $APP ($(lipo -archs "$APP/Contents/MacOS/MogoPrint"))"
echo "  실행: open $APP"
