# 모고 프린트 맥판

SwiftUI + PDFKit. macOS 14 이상.

## 빌드·실행·테스트

```bash
bash build_app.sh            # build/MogoPrint.app 생성 (명령줄 도구 mogo-cli도 앱 안 Contents/MacOS에 들어감)
open build/MogoPrint.app
swift test                   # 단위 테스트
```

Xcode로 작업하려면 `Package.swift`를 연다. 다만 Dock 아이콘에 파일을 놓는 기능과 앱 아이콘은
`Resources/`가 들어간 .app 번들(위 스크립트)에서만 동작한다.

## 구조

```
Sources/MogoCore/        자르기·배치·인쇄 로직 (UI 없음)
  ExamDocument.swift     PDF 불러오기, 홀/짝 형 감지, 페이지별 내용 영역(50dpi 렌더링, 여러 스레드)
  Imposer.swift          자를 범위·배율 계산, 손 조정, 빈 쪽, A4에 벡터로 그리기, 폴더 펼치기
  Printing.swift         lp(CUPS)로 인쇄, 드라이버 옵션 자동 추가, PPD에서 인쇄 불가 여백 읽기
Sources/MogoPrint/       SwiftUI 앱 (DebugSnapshot.swift는 개발용 자동 UI 점검)
Sources/mogo-cli/        명령줄 도구
Tests/MogoCoreTests/     합성 PDF 시험, 실제 기출 시험, 정답값 비교, mogo-cli 실행 시험
Tools/make-demo.swift    docs/demo 예시 문제지 만들기 (swift Tools/make-demo.swift ../docs/demo)
Tools/readme-images/     README 그림 만들기 (사용법은 파일 맨 위 주석)
Resources/               Info.plist, AppIcon.icns, IconSource/(생성한 아이콘 원본과 후보)
```

규칙은 [`../docs/ALGORITHM.md`](../docs/ALGORITHM.md)에 플랫폼과 상관없이 적어 두었다.

## 테스트
- 합성 PDF로 하는 시험은 언제나 돈다(형 감지, 잉크 영역, /Rotate, 크기 섞인 파일, 손 조정, 빈 쪽, A4 여백, lp 인자, PPD 여백).
- `CLITests`는 빌드된 `mogo-cli`를 docs/demo 예시 문제지로 직접 돌린다(요약, JSON, 저장, --dry-run 인쇄, 잘못된 인자).
- 저장소 맨 위 `Samples/`에 기출 PDF가 있으면 실제 시험지 시험과 정답값 비교(`GoldenTests`)도 돈다. 없으면 건너뛴다.
  샘플은 평가원 저작물이라 git에 넣지 않는다. 정답값 파일의 경로대로 받아 두면 된다.
- 규칙을 일부러 바꿨다면 정답값을 다시 쓴다: `MOGO_UPDATE_GOLDEN=1 swift test --filter GoldenTests`.
  윈도우판도 같은 파일로 시험하므로 바뀐 이유를 커밋에 남긴다.

## 개발용 자동 UI 점검
화면 기록·손쉬운 사용 권한 없이 앱이 스스로 창을 그려 저장한다. 다른 앱의 포커스는 뺏지 않는다.

```bash
build/MogoPrint.app/Contents/MacOS/MogoPrint --snapshot-dir /tmp/snap \
  --snapshot-drop "$PWD/../Samples/2026수능_국어_문제지.pdf" \
  --snapshot-drop-more "$PWD/../Samples/2026수능_영어_문제지.pdf" --snapshot-quit
```

- `--snapshot-drop`: 빈 창에 끌어다 놓기를 흉내 낸다. AppKit이 드롭 때 부르는 `draggingEntered` → `performDragOperation`을
  SwiftUI가 숨겨 둔 드롭 뷰에 그대로 호출한다.
- `--snapshot-drop-more`: 미리보기 위에 하나 더 놓는다(PDF 뷰가 드롭을 가로채지 않는지).
- 저장: `empty.png`, `main.png`, `preview.pdf`(미리보기 내용. 비트맵 캡처에는 PDF 뷰가 하얗게 나온다),
  `adjust.png`(자르기 손보기 창), `confirm.png`(인쇄 확인 창), `report.json`(쪽수·배율·드롭 결과 등).
- 캡처 모양: `--snapshot-appearance light|dark`, `--snapshot-size 1180x780`(창 내용 크기), `--snapshot-copies 2`.
  PNG는 2배 해상도이고, 앱이 비활성이어도 활성 창 모양으로 그린다.
- **값 없는 옵션(`--snapshot-quit`)은 반드시 맨 뒤에 둔다.** macOS는 `-이름 값`을 짝지어 읽어서, 값 없는 옵션이 중간에 끼면
  뒤의 PDF 경로가 '실행할 때 열 파일'로 처리되고 SwiftUI가 창을 만들지 않는다.
- Dock·Finder로 여는 경로: `open -n -g -a "$PWD/build/MogoPrint.app" 파일.pdf --args --snapshot-dir … --snapshot-quit`.
- 백그라운드로 띄운 앱은 스스로 활성화되지 않아 팝오버가 열리지 않는다. 그래서 자르기 손보기 창은 화면 밖 창에 그려서 확인한다.

## CLI

`build/MogoPrint.app/Contents/MacOS/mogo-cli --help`. 옵션과 예는 저장소 맨 위 README의 "명령줄로 쓰기".
`-p`는 앱의 인쇄 버튼과 같은 함수(`Printing.submit`)로 보낸다.

## 인쇄 경로 확인 기록 (Brother DCP-T825DW, AirPrint)
- 종이 없이: `cupsfilter -p /etc/cups/ppd/<큐>.ppd -m image/urf …`로 프린터에 넘어가는 래스터를 풀어 보면
  5mm 테두리가 사방 5.0mm에 그대로 찍히고(CUPS가 따로 줄이지 않음), 8비트 흑백, 긴 쪽 양면으로 넘어간다.
  이 프린터의 인쇄 불가 여백은 사방 3.0mm.
- 실제 대기열: 같은 옵션으로 `lp -H hold` 보류 작업을 보내 속성을 확인하고 취소했다.
- 종이: 2026 수능 국어 1·2쪽을 양면으로 뽑아 방향 맞음, 잘림 없음을 확인했다(2026-11-04).

## 알려진 한계
- 한컴(HWP)으로 만든 평가원 PDF는 글자 대응표(`Unidocs-HWP2002-UCS2`)를 Quartz가 새 PDF로 옮기지 못해서,
  "PDF로 저장"한 결과에서는 본문 글자 검색·복사가 안 된다. 글자 모양은 벡터 그대로라 인쇄와는 상관없다.

## 할 일
- [ ] 서명·공증한 앱을 GitHub Releases로 배포
- [ ] 정답표를 맨 뒤로 모으기, 평가원·EBSi에서 바로 받기 (평가원 게시판: 수능 1500234, 모의평가 1500236,
      `boardCnts/fileDown.do?fileSeq=…`, 탐구·옛 문제지는 ZIP이고 파일명이 CP949)
- [ ] 윈도우판 (`../windows/`, 규칙은 `../docs/ALGORITHM.md`)
