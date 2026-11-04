import MogoCore
import XCTest

final class PrintingTests: XCTestCase {
    /// Brother DCP-T825DW(AirPrint)의 실제 `lpoptions -l` 출력.
    let brother = """
    ColorModel/Color Mode: Gray *RGB
    cupsPrintQuality/Quality: Draft *Normal High
    Duplex/2-Sided Printing: None *DuplexNoTumble DuplexTumble
    PageSize/Media Size: 215x345mm 3.5x5 *A4 A4.Fullbleed A5 Letter Custom.WIDTHxHEIGHT
    MediaType/MediaType: stationery photographic-glossy *any
    InputSlot/Media Source: auto by-pass-tray tray-1
    """

    let file = URL(fileURLWithPath: "/tmp/exam.pdf")

    func testParseDriverOptions() {
        let o = Printing.parseDriverOptions(brother)
        XCTAssertEqual(o["ColorModel"], ["Gray", "RGB"])
        XCTAssertEqual(o["Duplex"], ["None", "DuplexNoTumble", "DuplexTumble"])
        XCTAssertTrue(o["PageSize"]?.contains("A4") ?? false)
        XCTAssertEqual(o["InputSlot"], ["auto", "by-pass-tray", "tray-1"])
    }

    func testDefaultArgumentsForBrother() {
        let args = Printing.arguments(file: file, settings: PrintSettings(printer: "Brother_DCP_T825DW_2"),
                                      title: "국어", driverOptions: Printing.parseDriverOptions(brother))
        let joined = args.joined(separator: " ")
        XCTAssertTrue(joined.hasPrefix("-d Brother_DCP_T825DW_2 -n 1 -t 국어"))
        for opt in ["media=A4", "sides=two-sided-long-edge", "print-color-mode=monochrome",
                    "PageSize=A4", "Duplex=DuplexNoTumble", "ColorModel=Gray"] {
            XCTAssertTrue(args.contains(opt), opt)
        }
        XCTAssertFalse(args.contains("collate=true"))
        XCTAssertEqual(args.last, file.path)
    }

    func testSingleSidedColorCopies() {
        var s = PrintSettings(printer: "P")
        s.duplex = false
        s.grayscale = false
        s.copies = 3
        let args = Printing.arguments(file: file, settings: s, title: "t", driverOptions: Printing.parseDriverOptions(brother))
        XCTAssertTrue(args.contains("sides=one-sided"))
        XCTAssertTrue(args.contains("Duplex=None"))
        XCTAssertTrue(args.contains("print-color-mode=color"))
        XCTAssertTrue(args.contains("ColorModel=RGB"))
        XCTAssertTrue(args.contains("collate=true"))
        XCTAssertEqual(args[args.firstIndex(of: "-n")! + 1], "3")
    }

    func testPrinterWithoutDriverOptionsGetsOnlyStandardOptions() {
        let args = Printing.arguments(file: file, settings: PrintSettings(printer: "Plain"), title: "t", driverOptions: [:])
        XCTAssertTrue(args.contains("sides=two-sided-long-edge"))
        XCTAssertFalse(args.contains { $0.hasPrefix("Duplex=") || $0.hasPrefix("ColorModel=") || $0.hasPrefix("PageSize=") })
    }

    func testCopiesAreAtLeastOne() {
        var s = PrintSettings(printer: "P")
        s.copies = 0
        let args = Printing.arguments(file: file, settings: s, title: "t", driverOptions: [:])
        XCTAssertEqual(args[args.firstIndex(of: "-n")! + 1], "1")
    }

    func testParseJobID() {
        XCTAssertEqual(Printing.parseJobID("request id is Brother_DCP_T825DW_2-123 (1 file(s))\n"), "Brother_DCP_T825DW_2-123")
        XCTAssertNil(Printing.parseJobID("lp: The printer or class does not exist."))
    }

    func testParseA4MarginFromPPD() throws {
        let ppd = """
        *PaperDimension A4: "595.2756 841.8898"
        *ImageableArea A4: "8.5039 8.5039 586.7717 833.3858"
        *ImageableArea A4.Fullbleed: "0.0000 0.0000 595.2756 841.8898"
        """
        XCTAssertEqual(try XCTUnwrap(Printing.parseA4MarginMM(ppd: ppd)), 3.0, accuracy: 0.01)

        // 네 변이 다르면 가장 큰 값.
        let laser = """
        *PaperDimension A4/A4: "595 842"
        *ImageableArea A4/A4: "12 12 583 828"
        """
        XCTAssertEqual(try XCTUnwrap(Printing.parseA4MarginMM(ppd: laser)), 14 / pointsPerMM, accuracy: 0.01)
        XCTAssertNil(Printing.parseA4MarginMM(ppd: "*PaperDimension Letter: \"612 792\""))
    }

    func testHardwareMarginRejectsOddNames() {
        XCTAssertNil(Printing.hardwareMarginMM(printer: ""))
        XCTAssertNil(Printing.hardwareMarginMM(printer: "../../etc/passwd"))
    }
}
