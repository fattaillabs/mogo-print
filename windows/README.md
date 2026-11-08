# 모고 프린트 Windows 버전

C#(.NET 10)과 WPF로 만든 Windows 앱과 명령줄 도구입니다. PDF를 읽고 그리는 일은 PDFium(크롬의 PDF 엔진)이 합니다.
Windows 10·11 64비트에서 동작하며, 화면은 Windows 11 기본 모양(Fluent 테마)을 따르고 밝게·어둡게 설정에 맞춰 바뀝니다.

## 빌드와 테스트

[.NET 10 SDK](https://dotnet.microsoft.com/download)가 필요합니다.

```powershell
dotnet build MogoPrint.slnx -c Release
dotnet run --project MogoPrint                    # 앱 실행
dotnet test Mogo.Core.Tests                       # 테스트
powershell -File publish.ps1 -Version 0.1.0       # 배포용 단일 exe와 zip (artifacts\)
```

`publish.ps1`은 .NET과 PDFium을 exe 안에 넣은 단일 실행 파일을 만들고 zip으로 묶습니다(64비트, exe 약 66MB).
zip 안에는 exe 하나만 들어 있어 받는 사람은 압축을 풀고 바로 실행합니다.
`artifacts\MogoPrint-windows-x64.zip`과 `artifacts\mogo-cli-windows-x64.zip`을 GitHub Releases에 올리면
최상위 README의 고정 링크(`releases/latest/download/…`)가 그 파일을 가리킵니다. 파일 이름은 바꾸지 않습니다.

## 구조

```
Mogo.Core/          자르기·배치·인쇄 로직 (UI 없음)
  Pdfium.cs         PDFium 함수 선언, PDF 열기·쪽 정보·글자 추출·렌더링·저장
  SourceFile.cs     PDF 불러오기, 홀·짝 형·선택과목 감지, 쪽별 내용 영역 감지(50dpi 렌더링)
  Imposer.cs        자를 범위와 배율, 수동 조정, 빈 쪽, A4에 벡터로 놓기, 여백 조정 점선 계산, 폴더 펼치기
  Kice.cs           평가원 기출문제 게시판 읽기·받기, ZIP 풀기(CP949 파일 이름)
  Printing.cs       인쇄(PDFium이 프린터 장치에 직접 그림), PrintTicket으로 흑백·양면 설정, 인쇄 불가 여백
  Models.cs         좌표·설정·결과 형식
Mogo.Cli/           명령줄 도구 mogo-cli
MogoPrint/          WPF 앱
  MainWindow        첫 화면, 파일 목록과 설정, 미리보기
  ManualCropView    여백 수동 조정(네 변 점선)
  Dialogs           인쇄 확인 창, 평가원 받기 창
  Snapshot          개발용 자동 UI 점검
Mogo.Core.Tests/    xUnit 테스트
publish.ps1         배포용 빌드
```

자르기와 배치 규칙은 맥 버전과 같으며 [`../docs/ALGORITHM.md`](../docs/ALGORITHM.md)에 정리되어 있습니다.

## 테스트

- 합성 PDF 테스트는 시험용 PDF를 PDFium으로 그때그때 만들어(검은 사각형, /Rotate, 맑은 고딕 한글) 형·선택과목 감지, 내용 영역,
  회전, 크기가 섞인 파일, 수동 조정, 빈 쪽, A4 배치, 글자 보존을 검사합니다. 암호 걸린 PDF만 맥 PDFKit으로 만든 `Fixtures/locked.pdf`를 씁니다.
- `CliTests`는 빌드된 `mogo-cli`를 docs/demo 예시 문제지로 실행해 요약, JSON, 저장, 인쇄 설정, 파일로 인쇄, 잘못된 인자 처리를 확인합니다.
- `PrintingTests`는 "Microsoft Print to PDF"로 파일에 인쇄한 결과를 다시 읽어 A4 용지, 여백, 쪽 순서, 흑백 변환, 부수를 확인합니다.
- `SpoolTests`는 인쇄 대기열을 멈춰 두고 작업을 보내 드라이버가 받은 설정(DEVMODE와 PrintTicket)을 읽은 뒤 작업을 지웁니다(맥의 `lp -H hold`와 같은 확인).
  관리자 권한과 시험용 프린터가 필요하고, 없으면 건너뜁니다.

  ```powershell
  Add-PrinterDriver -Name "Microsoft PS Class Driver"
  Add-PrinterPort -Name "C:\temp\mogo-hold.prn"
  Add-Printer -Name "Mogo Hold Test" -DriverName "Microsoft PS Class Driver" -PortName "C:\temp\mogo-hold.prn"
  ```

- 저장소 최상위 `Samples/`에 실제 시험지 PDF가 있으면 실제 시험지 테스트와 기준값 비교(`GoldenTests`)도 실행됩니다.
  기준값은 맥 버전이 만든 [`../docs/expected/samples.json`](../docs/expected/samples.json)이고, 두 버전의 허용 오차는 여백 ±1.5mm, 배율 ±0.01입니다.
  2026년 11월 실측(시험지 23개)에서 최대 차이는 여백 1.40mm, 배율 0.0013이었습니다. 연한 회색 저작권 문구를 두 렌더러가 조금 다르게 그리기 때문입니다.
- 평가원 홈페이지에 실제로 접속하는 테스트는 `$env:MOGO_NETWORK_TESTS="1"; dotnet test Mogo.Core.Tests --filter LiveDownload`로만 실행됩니다.

## 개발용 자동 UI 점검

원격 데스크톱 없이 앱이 스스로 창을 그려(RenderTargetBitmap) PNG로 저장합니다. SSH 세션에서도 동작합니다.

```powershell
Start-Process MogoPrint.exe -Wait -ArgumentList @(
  "--snapshot-dir", "C:\snap", "--snapshot-appearance", "light",
  "--snapshot-drop", "`"..\docs\demo\예시_국어_문제지.pdf`"", "--snapshot-drop", "`"..\docs\demo\예시_수학_문제지.pdf`"",
  "--snapshot-elective", "언매", "--snapshot-copies", "2", "--snapshot-drag-top", "5", "--snapshot-kice", "1", "--snapshot-quit")
```

- 저장 파일: `empty.png`(첫 화면), `main.png`(파일을 넣은 뒤), `manual.png`(여백 조정), `manual-drag.png`(위 점선을 끈 뒤),
  `confirm.png`(인쇄 확인 창), `kice.png`(평가원 받기 창, 목록만 불러옴), `report.json`(쪽수, 배율, 설정 줄, 여백 값, 오류 등).
- 그 밖의 옵션: `--snapshot-size 1180x780`, `--snapshot-printer 이름`. PNG는 2배 해상도이고 제목 표시줄은 들어가지 않습니다.
- 자동 점검 중에는 사용자가 저장해 둔 선택과목을 읽거나 쓰지 않고, 오류는 대화상자 대신 `report.json`에 적습니다.
- 끌어다 놓기는 WPF가 `DragEventArgs`를 밖에서 만들 수 없게 해 두어서, 놓았을 때 부르는 `AddAsync`를 직접 부릅니다.
- `MogoPrint.exe`는 창 프로그램이라 PowerShell에서 그냥 실행하면 끝나기를 기다리지 않습니다. `Start-Process -Wait`로 실행하고,
  띄어쓰기가 든 인자는 따옴표로 감쌉니다.
- 화면이 없는 세션(SSH 등)은 화면 크기가 1024×768이라 창이 그 폭으로 줄어듭니다.

## 인쇄 경로

- PDFium이 A4 결과 PDF를 프린터 장치(HDC)에 벡터 그대로 그립니다. 장치 원점은 인쇄 가능 영역의 왼쪽 위라서
  물리 여백만큼 당겨 종이 전체에 맞춥니다. 흑백이면 PDFium이 회색으로 그립니다.
- 용지·흑백·양면 설정은 PrintTicket(System.Printing)으로 만든 드라이버 DEVMODE에 넣습니다. Windows가 와이파이 프린터에
  자동으로 붙이는 IPP 드라이버 같은 v4 드라이버는 흑백·양면을 공개 DEVMODE가 아니라 PrintTicket으로 받기 때문입니다.
- 부수는 드라이버에 맡기지 않고 한 작업 안에서 문서를 되풀이해 보냅니다. Microsoft Print to PDF는 최대 1부이고,
  한 부씩 묶어 찍기를 지원하는지도 드라이버마다 다르기 때문입니다.
- 양면을 지원하지 않는 프린터면 단면으로 계산해 빈 쪽을 넣지 않고, 설정 칸과 인쇄 확인 창에서 알립니다.
- 검증 기록(Windows Server 2025, 가상 프린터): Microsoft Print to PDF로 파일에 인쇄해 잉크 위치가 만든 PDF와 1.5pt 안으로 같은 것,
  흑백 변환, 부수 순서(1·2·3·1·2·3)를 확인했습니다. 멈춘 대기열의 작업에서는 A4·세로·부수와 PrintTicket의 A4·흑백을 확인했습니다.

## 맥 버전과 다른 점

- "PDF로 저장"한 결과에서도 본문 글자를 검색하고 복사할 수 있습니다. PDFium은 한컴 PDF의 글자 대응표를 그대로 옮깁니다(맥은 Quartz가 옮기지 못함).
- 폴더는 "파일 선택" 창으로 고를 수 없어서 창에 끌어다 놓습니다.
- 코드 서명 인증서가 없어 처음 실행할 때 SmartScreen("Windows의 PC 보호") 창이 뜹니다.
