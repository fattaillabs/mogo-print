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
    /// CUPS 명령(lp·lpstat·lpoptions)이 붙을 곳. macOS CUPS는 내부 소켓(/private/var/run/cupsd)과 localhost:631을
    /// 둘 다 받는데, 내부 소켓은 큰 응답(lp가 작업 전에 묻는 프린터 정보 약 15KB)을 가끔 7KB쯤에서 끊어
    /// lp가 나머지를 끝없이 기다린다(2026-11 macOS 26.4 실측: 20번 중 8번, TCP는 0번).
    /// 그래서 localhost:631에 붙을 수 있으면 그쪽(TCP)을 쓴다. 사용자가 CUPS_SERVER를 정해 두었으면 그대로 둔다.
    public static let cupsServer: String? = {
        let env = ProcessInfo.processInfo.environment
        if let s = env["CUPS_SERVER"], !s.isEmpty { return nil }
        return canConnect(port: 631) ? "localhost" : nil
    }()

    /// 127.0.0.1의 포트에 1초 안에 붙을 수 있는지.
    static func canConnect(port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if r == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, 1000) == 1 else { return false }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return err == 0
    }

    private final class OutputBox: @unchecked Sendable { var data = Data() }

    /// 명령을 실행하고 출력(표준 출력+오류)을 돌려준다. timeout초 안에 끝나지 않으면 멈추고 timedOut.
    /// CUPS 명령은 cupsServer로 붙는다.
    @discardableResult
    static func run(_ tool: String, _ args: [String], timeout: TimeInterval = 20) -> (status: Int32, output: String, timedOut: Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        if let server = cupsServer, ["lp", "lpstat", "lpoptions"].contains((tool as NSString).lastPathComponent) {
            var env = ProcessInfo.processInfo.environment
            env["CUPS_SERVER"] = server
            p.environment = env
        }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return (-1, error.localizedDescription, false) }
        // 출력은 다른 스레드에서 끝까지 읽는다(기다리는 동안 파이프가 차서 멈추지 않게).
        let box = OutputBox()
        let readDone = DispatchSemaphore(value: 0)
        let handle = pipe.fileHandleForReading
        DispatchQueue.global().async {
            box.data = handle.readDataToEndOfFile()
            readDone.signal()
        }
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                exited.wait()
            }
        }
        _ = readDone.wait(timeout: .now() + 2)
        return (p.terminationStatus, String(decoding: box.data, as: UTF8.self), timedOut)
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

    /// lp가 이 시간 안에 끝나지 않으면 멈추고 알린다. 보통은 1초 안에 대기열로 들어간다.
    public static let submitTimeout: TimeInterval = 60

    /// 인쇄를 보내고 작업 번호를 돌려준다.
    public static func submit(file: URL, settings: PrintSettings, title: String,
                              timeout: TimeInterval = submitTimeout) throws -> String {
        let result = run("/usr/bin/lp", arguments(file: file, settings: settings, title: title), timeout: timeout)
        if result.timedOut {
            throw PrintError.failed("프린터가 응답하지 않아요. 프린터가 켜져 있고 같은 네트워크에 있는지 확인한 뒤 다시 인쇄해 주세요.")
        }
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
