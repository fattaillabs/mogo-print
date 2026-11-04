import CoreGraphics
import Foundation

public struct PrintSettings: Equatable, Sendable {
    public var printer: String
    public var copies: Int = 1
    public var duplex: Bool = true
    public var grayscale: Bool = true

    public init(printer: String) { self.printer = printer }
}

public enum PrintError: LocalizedError {
    case failed(String)
    public var errorDescription: String? {
        if case .failed(let msg) = self { return msg }
        return nil
    }
}

/// macOS 기본 인쇄 시스템(CUPS)의 lp 명령으로 바로 인쇄한다.
public enum Printing {
    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// 등록된 프린터 목록과 기본 프린터.
    public static func printers() -> (names: [String], defaultName: String?) {
        let names = run("/usr/bin/lpstat", ["-e"]).output
            .split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let d = run("/usr/bin/lpstat", ["-d"]).output
        let def = d.components(separatedBy: ": ").last?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (names, names.contains(def ?? "") ? def : names.first)
    }

    /// `lpoptions -l` 출력을 옵션 이름 → 값 목록으로 바꾼다. 기본값 표시(*)는 뗀다.
    /// 예: "Duplex/2-Sided Printing: None *DuplexNoTumble DuplexTumble"
    public static func parseDriverOptions(_ text: String) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = String(parts[0].split(separator: "/").first ?? "")
            let values = parts[1].split(separator: " ").map { $0.replacingOccurrences(of: "*", with: "") }
            out[key] = values
        }
        return out
    }

    /// 프린터 드라이버가 지원하는 옵션 이름과 값들 (lpoptions -l).
    static func driverOptions(_ printer: String) -> [String: [String]] {
        parseDriverOptions(run("/usr/bin/lpoptions", ["-p", printer, "-l"]).output)
    }

    /// 실제로 lp에 넘길 인자. 표준 IPP 옵션과 드라이버 옵션을 함께 넣는다.
    public static func arguments(file: URL, settings: PrintSettings, title: String) -> [String] {
        arguments(file: file, settings: settings, title: title, driverOptions: driverOptions(settings.printer))
    }

    public static func arguments(file: URL, settings: PrintSettings, title: String,
                                 driverOptions opts: [String: [String]]) -> [String] {
        var args = ["-d", settings.printer, "-n", String(max(1, settings.copies)), "-t", title,
                    "-o", "media=A4",
                    "-o", settings.duplex ? "sides=two-sided-long-edge" : "sides=one-sided",
                    "-o", settings.grayscale ? "print-color-mode=monochrome" : "print-color-mode=color"]
        // 여러 부를 뽑을 때 한 부씩 순서대로 나오게 한다.
        if settings.copies > 1 { args += ["-o", "collate=true"] }
        if let v = opts["PageSize"], v.contains("A4") { args += ["-o", "PageSize=A4"] }
        if let v = opts["Duplex"] {
            let want = settings.duplex ? "DuplexNoTumble" : "None"
            if v.contains(want) { args += ["-o", "Duplex=\(want)"] }
        }
        if let v = opts["ColorModel"] {
            let gray = ["Gray", "Grayscale", "Mono", "Black"].first { v.contains($0) }
            let color = ["RGB", "Color", "CMYK"].first { v.contains($0) }
            if settings.grayscale, let g = gray { args += ["-o", "ColorModel=\(g)"] }
            if !settings.grayscale, let c = color { args += ["-o", "ColorModel=\(c)"] }
        }
        return args + [file.path]
    }

    /// lp 출력에서 작업 번호를 뽑는다. 예: "request id is Brother-12 (1 file(s))" → "Brother-12"
    public static func parseJobID(_ output: String) -> String? {
        guard let r = output.range(of: #"request id is (\S+)"#, options: .regularExpression) else { return nil }
        return output[r].components(separatedBy: " ").last
    }

    /// 인쇄를 보내고 작업 번호를 돌려준다.
    public static func submit(file: URL, settings: PrintSettings, title: String) throws -> String {
        let result = run("/usr/bin/lp", arguments(file: file, settings: settings, title: title))
        guard result.status == 0 else {
            let msg = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PrintError.failed(msg.isEmpty ? "인쇄 요청이 실패했어요." : msg)
        }
        return parseJobID(result.output) ?? ""
    }

    // MARK: 인쇄 불가 여백

    /// PPD 내용에서 A4의 인쇄 불가 여백(네 변 중 가장 큰 값, mm)을 구한다.
    /// 예: *ImageableArea A4: "8.5039 8.5039 586.7717 833.3858", *PaperDimension A4: "595.2756 841.8898"
    public static func parseA4MarginMM(ppd: String) -> CGFloat? {
        func numbers(_ key: String) -> [CGFloat]? {
            guard let line = ppd.split(separator: "\n").first(where: { $0.hasPrefix("*\(key) A4:") || $0.hasPrefix("*\(key) A4/") }),
                  let q1 = line.firstIndex(of: "\""), let q2 = line.lastIndex(of: "\""), q1 < q2
            else { return nil }
            let nums = line[line.index(after: q1)..<q2].split(separator: " ").compactMap { Double($0) }.map { CGFloat($0) }
            return nums
        }
        guard let area = numbers("ImageableArea"), area.count == 4,
              let paper = numbers("PaperDimension"), paper.count == 2 else { return nil }
        let margins = [area[0], area[1], paper[0] - area[2], paper[1] - area[3]]
        return (margins.max() ?? 0) / pointsPerMM
    }

    /// 설치된 프린터의 A4 인쇄 불가 여백(mm). PPD가 없으면(네트워크에서만 보이는 프린터 등) nil.
    public static func hardwareMarginMM(printer: String) -> CGFloat? {
        let path = "/etc/cups/ppd/\(printer).ppd"
        guard !printer.isEmpty, !printer.contains("/"),
              let ppd = (try? String(contentsOfFile: path, encoding: .utf8))
                ?? (try? String(contentsOfFile: path, encoding: .isoLatin1))
        else { return nil }
        return parseA4MarginMM(ppd: ppd)
    }
}
