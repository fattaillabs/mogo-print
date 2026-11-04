import Foundation
import MogoCore

// mogo-cli: 모고 프린트 명령줄 도구. 앱과 같은 MogoCore로 자르고 배치하고 인쇄한다.

let usage = """
모고 프린트 CLI: 모의고사 PDF(A3)의 여백을 잘라 A4에 맞추고, 저장하거나 바로 인쇄합니다.

사용법:
  mogo-cli [옵션] <PDF나 폴더>...

  입력만 주면 어떻게 배치될지 요약만 보여 줍니다. 폴더는 하위 폴더까지 펼칩니다.

결과:
  -o, --output <파일.pdf>   A4로 배치한 PDF를 저장
  -p, --print               프린터로 바로 인쇄 (기본: 양면 긴 쪽 넘김, 흑백, 1부)
      --dry-run             --print와 같이 쓰면 실제로 보내지 않고 lp 명령만 보여 줌
      --json                요약을 JSON으로 출력

배치:
      --variant odd|even|all  홀·짝 합본 파일에서 고를 형 (기본 odd)
      --margin <mm>           종이 여백 (기본 5)
      --trim <위,아래,왼쪽,오른쪽>  모든 파일의 자를 범위를 mm 단위로 손봄 (+는 더 자르고 -는 넓힘)
      --whole-page            자동 자르기를 끄고 페이지 전체를 씀

인쇄:
      --printer <이름>        프린터 (기본: 시스템 기본 프린터, 목록은 --list-printers)
      --copies <N>            부수
      --single-sided          단면
      --color                 컬러
      --list-printers         프린터 목록과 기본 프린터를 보여 줌

  -h, --help                이 도움말
  -v, --version             버전

예:
  mogo-cli ~/Downloads/2026수능_국어_문제지.pdf
  mogo-cli --variant even -o 국어_짝수형_A4.pdf ~/Downloads/2026수능_국어_문제지.pdf
  mogo-cli -p --copies 2 ~/Downloads/모의고사/
"""

let version = "0.1.0"

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write("mogo-cli: \(message)\n".data(using: .utf8)!)
    exit(code)
}

// MARK: 인자 읽기

var args = Array(CommandLine.arguments.dropFirst())
var options = ImpositionOptions()
var settings = PrintSettings(printer: "")
var outputPath: String?
var doPrint = false, dryRun = false, json = false
var trim: CropAdjustment?
var printerName: String?
var inputs: [String] = []

func value(after flag: String) -> String {
    guard !args.isEmpty else { fail("\(flag) 뒤에 값이 필요해요") }
    return args.removeFirst()
}

while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "-h", "--help": print(usage); exit(0)
    case "-v", "--version": print("mogo-cli \(version)"); exit(0)
    case "-o", "--output": outputPath = value(after: a)
    case "-p", "--print": doPrint = true
    case "--dry-run": dryRun = true
    case "--json": json = true
    case "--variant":
        let v = value(after: a)
        guard let variant = ["odd": ExamVariant.odd, "even": .even, "all": .all][v] else {
            fail("--variant는 odd, even, all 중 하나예요 (받은 값: \(v))")
        }
        options.variant = variant
    case "--margin":
        let v = value(after: a)
        guard let m = Double(v), m >= 0, m < 50 else { fail("--margin은 mm 숫자예요 (받은 값: \(v))") }
        options.paperMarginMM = m
    case "--trim":
        let v = value(after: a)
        let n = v.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }.map { CGFloat($0) }
        guard n.count == 4 else { fail("--trim은 위,아래,왼쪽,오른쪽 네 숫자예요 (예: 5,0,0,0)") }
        trim = CropAdjustment(top: n[0], bottom: n[1], left: n[2], right: n[3], wholePage: trim?.wholePage ?? false)
    case "--whole-page":
        trim = trim ?? CropAdjustment()
        trim?.wholePage = true
    case "--printer": printerName = value(after: a)
    case "--copies":
        let v = value(after: a)
        guard let c = Int(v), c >= 1, c <= 99 else { fail("--copies는 1~99예요 (받은 값: \(v))") }
        settings.copies = c
    case "--single-sided": settings.duplex = false
    case "--color": settings.grayscale = false
    case "--list-printers":
        let found = Printing.printers()
        if found.names.isEmpty { print("설치된 프린터가 없어요.") }
        for name in found.names { print(name == found.defaultName ? "* \(name) (기본)" : "  \(name)") }
        exit(0)
    default:
        if a.hasPrefix("-") && a.count > 1 { fail("모르는 옵션이에요: \(a)\n도움말: mogo-cli --help") }
        inputs.append(a)
    }
}

guard !inputs.isEmpty else { print(usage); exit(1) }

// MARK: 불러오기와 배치

let urls = URL.expandPDFs(inputs.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) })
guard !urls.isEmpty else { fail("PDF를 찾지 못했어요: \(inputs.joined(separator: " "))") }
let loaded = SourceFile.load(urls)
for (url, file) in zip(urls, loaded) where file == nil {
    FileHandle.standardError.write("mogo-cli: 열지 못함(암호가 걸렸거나 손상됨): \(url.path)\n".data(using: .utf8)!)
}
let files = loaded.compactMap { $0 }
guard !files.isEmpty else { fail("열 수 있는 PDF가 없어요") }
if let trim { for f in files { options.adjustments[f.url] = trim } }

// 앱과 같은 규칙: 양면이면 홀수 쪽 파일 뒤에 빈 쪽, 양면으로 여러 부면 마지막 파일 뒤에도.
options.padSectionsToEven = settings.duplex
options.padEndToEven = settings.duplex && settings.copies > 1

guard let result = Imposer.impose(files: files, options: options) else { fail("A4로 배치하지 못했어요", code: 2) }
let sheets = settings.duplex ? (result.pageCount + 1) / 2 : result.pageCount

// MARK: 결과

func mm(_ pt: CGFloat) -> Double { (Double(pt / pointsPerMM) * 10).rounded() / 10 }
/// JSON에 24.300000000000001처럼 찍히지 않게 정해진 자릿수의 십진수로 넣는다.
func dec(_ v: Double, _ digits: Int = 1) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.\(digits)f", v)) }

if json {
    let doc: [String: Any] = [
        "output_pages": result.pageCount,
        "sheets": sheets,
        "variant": [ExamVariant.odd: "odd", .even: "even", .all: "all"][options.variant]!,
        "paper_margin_mm": dec(Double(options.paperMarginMM)),
        "files": result.sections.map { s -> [String: Any] in
            let size = s.pageSize, crop = s.crop
            return [
                "path": s.file.url.path,
                "pages": s.file.pageCount,
                "used_pages": s.pageIndices.map { $0 + 1 },
                "both_variants": s.file.hasBothVariants,
                "page_size_mm": [dec(mm(size.width)), dec(mm(size.height))],
                "crop_margin_mm": ["left": dec(mm(crop.minX)), "top": dec(mm(size.height - crop.maxY)),
                                   "right": dec(mm(size.width - crop.maxX)), "bottom": dec(mm(crop.minY))],
                "scale": dec(Double(s.scale), 4),
                "blank_page_after": s.padsBlankPage,
            ]
        },
    ]
    let data = try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    print(String(decoding: data, as: UTF8.self))
} else {
    for s in result.sections {
        let size = s.pageSize, crop = s.crop
        var tags: [String] = []
        if s.file.hasBothVariants { tags.append("홀·짝 합본→\(options.variant.rawValue)") }
        if s.padsBlankPage { tags.append("+빈 쪽") }
        print("\(s.file.name): \(s.file.pageCount)쪽 → \(s.pageIndices.count)쪽, \(Int((s.scale * 100).rounded()))%"
              + "  (자른 여백 왼\(Int(mm(crop.minX))) 위\(Int(mm(size.height - crop.maxY)))"
              + " 오\(Int(mm(size.width - crop.maxX))) 아래\(Int(mm(crop.minY)))mm)"
              + (tags.isEmpty ? "" : "  " + tags.joined(separator: ", ")))
    }
    print("합계: A4 \(result.pageCount)쪽, 종이 \(sheets)장\(settings.duplex ? " (양면)" : "")")
}

var outURL: URL?
if let outputPath {
    let url = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath)
    do { try result.data.write(to: url) } catch { fail("저장하지 못했어요: \(error.localizedDescription)") }
    if !json { print("저장: \(outputPath)") }
    outURL = url
}

if doPrint {
    guard let printer = printerName ?? Printing.printers().defaultName else { fail("프린터가 없어요 (--list-printers)") }
    settings.printer = printer
    let file = outURL ?? FileManager.default.temporaryDirectory.appendingPathComponent("mogo-\(UUID().uuidString.prefix(8)).pdf")
    let title = files.map(\.name).joined(separator: ", ")
    if let m = Printing.hardwareMarginMM(printer: printer), options.paperMarginMM + 0.05 < m, !json {
        print("주의: 이 프린터는 가장자리 \(String(format: "%.1f", m))mm 안쪽만 찍혀요. --margin을 늘리는 게 좋아요.")
    }
    if dryRun {
        let lpArgs = Printing.arguments(file: file, settings: settings, title: title)
        print("보낼 명령: lp " + lpArgs.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " "))
        exit(0)
    }
    if outURL == nil {
        do { try result.data.write(to: file) } catch { fail("임시 파일을 쓰지 못했어요: \(error.localizedDescription)") }
    }
    defer { if outURL == nil { try? FileManager.default.removeItem(at: file) } }
    do {
        let id = try Printing.submit(file: file, settings: settings, title: title)
        if !json {
            print("인쇄를 보냈어요: \(printer.replacingOccurrences(of: "_", with: " "))"
                  + "\(id.isEmpty ? "" : " · 작업 \(id)") · \(settings.duplex ? "양면" : "단면") · \(settings.grayscale ? "흑백" : "컬러") · \(settings.copies)부")
        }
    } catch {
        fail("인쇄하지 못했어요: \(error.localizedDescription)", code: 4)
    }
}
