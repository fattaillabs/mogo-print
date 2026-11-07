# 모고 프린트 macOS 버전

SwiftUI와 PDFKit으로 만든 macOS 앱과 명령줄 도구입니다. macOS 14 이상에서 동작합니다.

## 빌드와 테스트

```bash
bash build_app.sh            # build/MogoPrint.app 생성 (명령줄 도구 mogo-cli는 앱의 Contents/MacOS에 함께 들어감)
ARCHS="arm64 x86_64" bash build_app.sh   # Apple Silicon·Intel 겸용
open build/MogoPrint.app
swift test                   # 테스트 실행
```

Xcode에서 작업하려면 `Package.swift`를 엽니다. 다만 Dock 아이콘에 파일을 놓는 기능과 앱 아이콘은
`Resources/`가 들어간 .app 번들(위 스크립트로 만든 앱)에서만 동작합니다.

## 배포

`release.sh`가 Apple Silicon·Intel 겸용 빌드, Developer ID 서명, 애플 공증, DMG 만들기(서명·공증)를 한 번에 합니다.

```bash
# 공증 자격 증명: notarytool 키체인 프로필이나 App Store Connect API 키 중 하나
NOTARY_PROFILE=<프로필 이름> bash release.sh 0.1.0
NOTARY_KEY=<AuthKey_XXXX.p8 경로> NOTARY_KEY_ID=<키 ID> NOTARY_ISSUER=<Issuer ID> bash release.sh 0.1.0

gh release create v0.1.0 build/release/MogoPrint.dmg --title "모고 프린트 0.1.0" --notes-file <릴리스 노트>
```

- 키체인에 `Developer ID Application` 인증서가 있어야 합니다(다른 인증서는 `SIGN_ID`로 지정).
- 릴리스 파일 이름은 항상 `MogoPrint.dmg`로 둡니다. README의 고정 링크 `releases/latest/download/MogoPrint.dmg`가 이 이름을 가리킵니다.
- 공증 없이 서명·DMG까지만 시험하려면 `SKIP_NOTARIZE=1`.
- 스크립트 끝에서 `spctl`로 DMG와 앱이 "Notarized Developer ID"로 통과하는지 확인합니다.

## 구조

```
Sources/MogoCore/        자르기·배치·인쇄 로직 (UI 없음)
  ExamDocument.swift     PDF 불러오기, 홀·짝 형·선택과목 감지, 쪽별 내용 영역 감지(50dpi 렌더링, 멀티스레드)
  Imposer.swift          자를 범위와 배율 계산, 수동 조정, 빈 쪽, A4에 벡터로 그리기, 폴더 펼치기
  CropGuides.swift       여백 수동 조정 화면의 네 변 점선 계산(끌기 제한, 점선 위치 ↔ 조정값)
  KICEArchive.swift      평가원 기출문제 게시판 읽기·받기(학년도, 영역, 첨부 분류, ZIP 풀기)
  ZipArchive.swift       평가원 ZIP 풀기(저장·deflate, CP949 파일 이름). macOS 기본 unzip은 이름이 깨진다
  Printing.swift         lp(CUPS) 인쇄, 드라이버 옵션 자동 추가, PPD에서 인쇄 불가 여백 읽기
Sources/MogoPrint/       SwiftUI 앱 (KICEDownloadView.swift는 평가원 받기 창, DebugSnapshot.swift는 개발용 자동 UI 점검)
Sources/mogo-cli/        명령줄 도구
Tests/MogoCoreTests/     합성 PDF 테스트, 실제 시험지 테스트, 기준값 비교, 여백 조정 점선 계산, mogo-cli 실행 테스트
Tools/make-demo.swift    docs/demo 예시 문제지 생성 (swift Tools/make-demo.swift ../docs/demo)
Tools/readme-images/     README 이미지 생성 (사용법은 파일 첫머리 주석 참고)
Resources/               Info.plist, AppIcon.icns, IconSource/(아이콘 원본과 후보)
```

자르기와 배치 규칙은 플랫폼과 관계없이 [`../docs/ALGORITHM.md`](../docs/ALGORITHM.md)에 정리되어 있습니다.

## 테스트

- 합성 PDF 테스트는 항상 실행됩니다. 형 감지, 내용 영역, /Rotate, 크기가 섞인 파일, 수동 조정, 빈 쪽, A4 여백, lp 인자, PPD 여백을 검사합니다.
- `CLITests`는 빌드된 `mogo-cli`를 docs/demo 예시 문제지로 직접 실행해 요약, JSON, 저장, `--dry-run` 인쇄, 잘못된 인자 처리를 확인합니다.
- 저장소 최상위 `Samples/`에 실제 시험지 PDF가 있으면 실제 시험지 테스트와 기준값 비교(`GoldenTests`)도 실행되고, 없으면 건너뜁니다.
  시험지는 평가원 저작물이라 저장소에 넣지 않습니다. 기준값 파일(`../docs/expected/samples.json`)에 적힌 경로대로 받아 두면 됩니다.
- 평가원 홈페이지에 실제로 접속하는 테스트는 `MOGO_NETWORK_TESTS=1 swift test --filter testLiveDownload`로만 실행됩니다
  (학년도 목록, 2026 수능 목록, PDF 받기, 2022 국어 ZIP 풀기, 6월 모평 목록). `Samples/_zips`에 실제 ZIP이 있으면 ZIP 테스트도 그것으로 확인합니다.
- 규칙을 의도적으로 바꿨다면 기준값을 다시 생성합니다: `MOGO_UPDATE_GOLDEN=1 swift test --filter GoldenTests`.
  Windows 버전도 같은 파일로 검증하므로 바꾼 이유를 커밋 메시지에 남깁니다.

## 개발용 자동 UI 점검

화면 기록이나 손쉬운 사용 권한 없이 앱이 스스로 창을 그려 저장합니다. 다른 앱의 포커스를 가져가지 않습니다.

```bash
build/MogoPrint.app/Contents/MacOS/MogoPrint --snapshot-dir /tmp/snap \
  --snapshot-drop "$PWD/../Samples/2026수능_국어_문제지.pdf" \
  --snapshot-drop-more "$PWD/../Samples/2026수능_영어_문제지.pdf" --snapshot-quit
```

- `--snapshot-drop`: 빈 창에 파일을 끌어다 놓는 동작을 재현합니다. AppKit이 드롭할 때 호출하는 `draggingEntered` → `performDragOperation`을
  SwiftUI의 숨은 드롭 뷰에 그대로 호출합니다.
- `--snapshot-drop-more`: 미리보기 위에 파일을 하나 더 놓습니다. PDF 뷰가 드롭을 가로채지 않는지 확인하는 용도입니다.
- 저장 파일: `empty.png`, `main.png`, `preview.pdf`(미리보기 내용), `manual.png`(여백 수동 조정 화면), `confirm.png`(인쇄 확인 창),
  `report.json`(쪽수, 배율, 드롭 결과 등).
- 캡처 옵션: `--snapshot-appearance light|dark`, `--snapshot-size 1180x780`(창 내용 크기), `--snapshot-copies 2`,
  `--snapshot-elective 언매`(여러 번), `--snapshot-kice 1`(평가원 받기 창을 열어 목록만 불러와 `kice.png`로 저장, 받지는 않음).
  자동 점검 중에는 사용자가 저장해 둔 선택과목을 읽거나 쓰지 않습니다.
  PNG는 2배 해상도이며, 앱이 비활성 상태여도 활성 창 모양으로 그립니다.
- **값이 없는 옵션(`--snapshot-quit`)은 반드시 맨 뒤에 둡니다.** macOS는 `-이름 값`을 한 쌍으로 읽기 때문에, 값이 없는 옵션이 중간에 있으면
  뒤의 PDF 경로가 '실행 시 열 파일'로 처리되고 SwiftUI가 창을 만들지 않습니다.
- Dock이나 Finder로 여는 경로는 `open -n -g -a "$PWD/build/MogoPrint.app" 파일.pdf --args --snapshot-dir … --snapshot-quit`로 확인합니다.
- 백그라운드로 실행한 앱은 스스로 활성화되지 않습니다. 이 상태에서는 앱 안에서 만든 마우스 이벤트가 '창을 앞으로 가져오는 첫 클릭'으로
  처리되어 버려지므로, 여백 조정 점선 끌기는 자동 점검으로 확인할 수 없습니다(`report.json`의 `manual_drag_*`).
  점선 위치 계산은 `CropGuidesTests`로 검증하고, 실제 끌기는 앱을 띄워 손으로 확인합니다.

## 명령줄 도구

`build/MogoPrint.app/Contents/MacOS/mogo-cli --help`로 도움말을 볼 수 있습니다. 옵션과 사용 예는 저장소 최상위 README의 "명령줄 도구"를 참고하세요.
`-p`는 앱의 인쇄 버튼과 같은 함수(`Printing.submit`)로 인쇄를 보냅니다.

## 인쇄 경로 검증 기록 (Brother DCP-T825DW, AirPrint)

- 종이 없이: `cupsfilter -p /etc/cups/ppd/<큐>.ppd -m image/urf …`로 프린터에 전달되는 래스터를 풀어 확인했습니다.
  5mm 테두리가 사방 5.0mm에 그대로 찍히고(CUPS가 따로 축소하지 않음), 8비트 흑백과 긴 쪽 양면으로 전달됩니다. 이 프린터의 인쇄 불가 여백은 사방 3.0mm입니다.
- 인쇄 대기열: 같은 옵션으로 `lp -H hold` 보류 작업을 보내 속성을 확인한 뒤 취소했습니다.
- 실제 출력: 2026학년도 수능 국어 1·2쪽을 양면으로 인쇄해 방향과 잘림이 없는 것을 확인했습니다(2026-11-04).

## 알려진 한계

- 한컴오피스(HWP)로 만든 평가원 PDF는 글자 대응표(`Unidocs-HWP2002-UCS2`)를 Quartz가 새 PDF로 옮기지 못합니다.
  그래서 "PDF로 저장"한 결과에서는 본문 글자 검색과 복사가 되지 않습니다. 글자 모양은 벡터 그대로라 인쇄 품질과는 관계없습니다.

## 할 일

- [x] 서명·공증한 앱을 GitHub Releases로 배포 (release.sh)
- [ ] 앱 안에서 새 버전 알림(Sparkle 등)
- [x] 평가원에서 바로 받기 (EBSi 교육청 학력평가는 아직)
- [x] Windows 버전 (`../windows/`, 규칙은 `../docs/ALGORITHM.md`)
