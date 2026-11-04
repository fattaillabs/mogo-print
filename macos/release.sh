#!/bin/bash
# 배포용 DMG 만들기: Apple Silicon·Intel 겸용 빌드 → Developer ID 서명 → 애플 공증 → DMG(서명·공증).
#
#   bash release.sh 0.1.0
#
# 필요한 것
# - 키체인에 "Developer ID Application" 인증서 (SIGN_ID로 직접 지정 가능)
# - 공증 자격 증명. 둘 중 하나:
#     NOTARY_PROFILE=<notarytool store-credentials로 저장한 프로필 이름>
#     NOTARY_KEY=<App Store Connect API 키 .p8 경로> NOTARY_KEY_ID=<키 ID> NOTARY_ISSUER=<Issuer ID>
# - SKIP_NOTARIZE=1 이면 공증 없이 서명·DMG까지만 만든다(시험용).
#
# 결과: build/release/MogoPrint.dmg (GitHub 릴리스에 이 이름 그대로 올리면 README의 고정 링크로 받아진다)
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?버전을 주세요. 예: bash release.sh 0.1.0}"
APP=build/MogoPrint.app
REL=build/release
DMG="$REL/MogoPrint.dmg"

SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
[ -n "$SIGN_ID" ] || { echo "Developer ID Application 인증서를 찾지 못했어요" >&2; exit 1; }

notary() {
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool "$@" --keychain-profile "$NOTARY_PROFILE"
  else
    : "${NOTARY_KEY:?NOTARY_PROFILE 또는 NOTARY_KEY·NOTARY_KEY_ID·NOTARY_ISSUER가 필요해요}"
    xcrun notarytool "$@" --key "$NOTARY_KEY" --key-id "${NOTARY_KEY_ID:?}" --issuer "${NOTARY_ISSUER:?}"
  fi
}

# 공증을 기다리고 결과가 Accepted가 아니면 로그를 보여 주고 멈춘다.
notarize() {
  local file="$1" out id
  echo "▸ 공증: $(basename "$file") (몇 분 걸려요)"
  out=$(notary submit "$file" --wait --output-format json)
  id=$(echo "$out" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
  if ! echo "$out" | grep -q '"status" *: *"Accepted"'; then
    echo "$out"
    notary log "$id" || true
    echo "공증이 통과하지 못했어요" >&2
    exit 1
  fi
  echo "  통과 ($id)"
}

echo "▸ 겸용 빌드"
ARCHS="arm64 x86_64" bash build_app.sh

echo "▸ 버전 $VERSION"
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"

echo "▸ 서명: $SIGN_ID"
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP/Contents/MacOS/mogo-cli"
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

rm -rf "$REL"
mkdir -p "$REL"
if [ "${SKIP_NOTARIZE:-}" != "1" ]; then
  ditto -c -k --keepParent "$APP" "$REL/MogoPrint.zip"
  notarize "$REL/MogoPrint.zip"
  xcrun stapler staple "$APP"
  rm "$REL/MogoPrint.zip"
fi

echo "▸ DMG"
ROOT="$REL/dmg"
mkdir -p "$ROOT"
cp -R "$APP" "$ROOT/"
ln -s /Applications "$ROOT/응용 프로그램"
hdiutil create -volname "모고 프린트 $VERSION" -srcfolder "$ROOT" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$ROOT"
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
if [ "${SKIP_NOTARIZE:-}" != "1" ]; then
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  echo "▸ 확인"
  spctl -a -vv -t install "$DMG"
  spctl -a -vv "$APP"
fi

echo "✓ $DMG ($(du -h "$DMG" | cut -f1), $(lipo -archs "$APP/Contents/MacOS/MogoPrint"))"
shasum -a 256 "$DMG"
