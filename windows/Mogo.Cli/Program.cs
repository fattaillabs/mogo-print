using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Mogo.Core;

// mogo-cli: 모고 프린트 명령줄 도구(윈도우). 앱과 같은 Mogo.Core로 자르고 배치하고 인쇄한다.
Console.OutputEncoding = Encoding.UTF8;

const string Usage = """
모고 프린트 CLI: 모의고사 PDF(A3)의 여백을 잘라 A4에 맞추고, 저장하거나 바로 인쇄합니다.

사용법:
  mogo-cli [옵션] <PDF나 폴더>...

  입력만 주면 어떻게 배치될지 요약만 보여 줍니다. 폴더는 하위 폴더까지 펼칩니다.

결과:
  -o, --output <파일.pdf>   A4로 배치한 PDF를 저장
  -p, --print               프린터로 바로 인쇄 (기본: 양면 긴 쪽 넘김, 흑백, 1부)
      --dry-run             --print와 같이 쓰면 실제로 보내지 않고 프린터가 받아들일 설정만 보여 줌
      --print-to-file <파일> --print와 같이 쓰면 프린터 출력 결과를 파일로 저장(Microsoft Print to PDF 등)
      --json                요약을 JSON으로 출력

배치:
      --variant odd|even|all  홀·짝 합본 파일에서 고를 형 (기본 odd)
      --elective <과목>       고를 선택과목: 화작, 언매, 확통, 미적, 기하 (국어·수학 하나씩, 여러 번 사용)
      --margin <mm>           종이 여백 (기본 5)
      --trim <위,아래,왼쪽,오른쪽>  모든 파일의 자를 범위를 mm 단위로 손봄 (+는 더 자르고 -는 넓힘)
      --whole-page            자동 자르기를 끄고 쪽 전체를 씀

평가원에서 받기:
      --download <시험> [학년도]  시험지를 받아 저장(시험: 수능, 6월, 9월). 학년도를 빼면 고를 수 있는 학년도를 보여 줌
      --area <영역,...>       받을 영역 (예: 국어,수학,사회탐구. 기본: 전체)
      --answers               정답표도 받기
      --to <폴더>             저장 폴더 (기본: 다운로드\모고 프린트)

인쇄:
      --printer <이름>        프린터 (기본: 기본 프린터, 목록은 --list-printers)
      --copies <N>            부수
      --single-sided          단면
      --color                 컬러
      --list-printers         프린터 목록과 기본 프린터를 보여 줌

  -h, --help                이 도움말
  -v, --version             버전
""";

var argList = new List<string>(args);
var options = new ImpositionOptions();
var settings = new PrintSettings("");
string? output = null, printerName = null, printToFile = null, downloadTo = null;
bool doPrint = false, dryRun = false, json = false, downloadAnswers = false;
CropAdjustment? trim = null;
KiceExam? downloadExam = null;
int? downloadYear = null;
var downloadAreas = new List<string>();
var inputs = new List<string>();

static void Fail(string message, int code = 1)
{
    Console.Error.WriteLine("mogo-cli: " + message);
    Environment.Exit(code);
}

// 식 안에서 쓰는 실패(값을 돌려주지 않고 끝낸다).
static T Die<T>(string message, int code = 1)
{
    Fail(message, code);
    return default!;
}

string Value(string flag)
{
    if (argList.Count == 0) Fail($"{flag} 뒤에 값이 필요해요");
    var v = argList[0];
    argList.RemoveAt(0);
    return v;
}

while (argList.Count > 0)
{
    var a = argList[0];
    argList.RemoveAt(0);
    switch (a)
    {
        case "-h": case "--help": Console.WriteLine(Usage); return 0;
        case "-v": case "--version": Console.WriteLine("mogo-cli 0.1.0 (Windows)"); return 0;
        case "-o": case "--output": output = Value(a); break;
        case "-p": case "--print": doPrint = true; break;
        case "--dry-run": dryRun = true; break;
        case "--print-to-file": printToFile = Path.GetFullPath(Value(a)); break;
        case "--json": json = true; break;
        case "--variant":
            {
                var v = Value(a);
                options = options with
                {
                    Variant = v switch { "odd" => ExamVariant.Odd, "even" => ExamVariant.Even, "all" => ExamVariant.All, _ => Die<ExamVariant>($"--variant는 odd, even, all 중 하나예요 (받은 값: {v})") }
                };
                break;
            }
        case "--elective":
            {
                var v = Value(a);
                var e = ElectiveInfo.Parse(v) ?? Die<Elective>($"--elective는 화작, 언매, 확통, 미적, 기하 중 하나예요 (받은 값: {v})");
                options = options.WithElective(e.Subject(), e);
                break;
            }
        case "--margin":
            {
                var v = Value(a);
                if (!double.TryParse(v, out var m) || m < 0 || m >= 50) Fail($"--margin은 mm 숫자예요 (받은 값: {v})");
                options = options with { PaperMarginMM = m };
                break;
            }
        case "--trim":
            {
                var n = Value(a).Split(',').Select(x => double.TryParse(x.Trim(), out var d) ? d : double.NaN).ToArray();
                if (n.Length != 4 || n.Any(double.IsNaN)) Fail("--trim은 위,아래,왼쪽,오른쪽 네 숫자예요 (예: 5,0,0,0)");
                trim = new CropAdjustment(n[0], n[1], n[2], n[3], trim?.WholePage ?? false);
                break;
            }
        case "--whole-page": trim = (trim ?? default) with { WholePage = true }; break;
        case "--printer": printerName = Value(a); break;
        case "--copies":
            {
                var v = Value(a);
                if (!int.TryParse(v, out var c) || c < 1 || c > 99) Fail($"--copies는 1~99예요 (받은 값: {v})");
                settings = settings with { Copies = c };
                break;
            }
        case "--single-sided": settings = settings with { Duplex = false }; break;
        case "--color": settings = settings with { Grayscale = false }; break;
        case "--list-printers":
            {
                var (names, def) = Printing.Printers();
                if (names.Count == 0) Console.WriteLine("설치된 프린터가 없어요.");
                foreach (var n in names) Console.WriteLine(n == def ? $"* {n} (기본)" : $"  {n}");
                return 0;
            }
        case "--download":
            {
                var v = Value(a);
                downloadExam = KiceExamInfo.Parse(v) ?? Die<KiceExam>($"--download 뒤에는 수능, 6월, 9월 중 하나를 써요 (받은 값: {v})");
                if (argList.Count > 0 && argList[0].Length == 4 && int.TryParse(argList[0], out var y)) { downloadYear = y; argList.RemoveAt(0); }
                break;
            }
        case "--area": downloadAreas.AddRange(Value(a).Split(',').Select(x => x.Trim()).Where(x => x.Length > 0)); break;
        case "--answers": downloadAnswers = true; break;
        case "--to": downloadTo = Value(a); break;
        default:
            if (a.StartsWith('-') && a.Length > 1) Fail($"모르는 옵션이에요: {a}\n도움말: mogo-cli --help");
            inputs.Add(a);
            break;
    }
}

if (downloadExam is { } exam)
{
    try
    {
        if (downloadYear is not { } year)
        {
            var years = await KiceArchive.YearsAsync(exam);
            Console.WriteLine($"{exam.FullName()}에서 고를 수 있는 학년도: " + string.Join(' ', years));
            return 0;
        }
        var rows = await KiceArchive.RowsAsync(exam, year);
        if (rows.Count == 0) Fail($"{year}학년도 {exam.FullName()} 시험지가 아직 올라와 있지 않아요");
        var wanted = downloadAreas.Count == 0 ? rows : rows.Where(r => downloadAreas.Any(x => r.Area.Replace(" ", "").StartsWith(x.Replace(" ", "")))).ToList();
        if (wanted.Count == 0) Fail("영역을 찾지 못했어요. 이 시험의 영역: " + string.Join(", ", rows.Select(r => r.Area)));
        var dir = KiceArchive.Folder(exam, year, downloadTo ?? KiceArchive.DefaultBaseDir);
        foreach (var row in wanted)
            foreach (var att in row.Papers.Concat(downloadAnswers ? row.Answers : Array.Empty<KiceAttachment>()))
                foreach (var p in await KiceArchive.SaveAsync(att, exam, year, dir)) Console.WriteLine(p);
        return 0;
    }
    catch (Exception ex)
    {
        Fail("받지 못했어요: " + ex.Message);
    }
}

if (inputs.Count == 0) { Console.WriteLine(Usage); return 1; }

var paths = FileExpander.ExpandPDFs(inputs);
if (paths.Count == 0) Fail("PDF를 찾지 못했어요: " + string.Join(' ', inputs));
var files = new List<SourceFile>();
foreach (var p in paths)
{
    var f = SourceFile.Load(p);
    if (f == null) Console.Error.WriteLine($"mogo-cli: 열지 못함(암호가 걸렸거나 손상됨): {p}");
    else files.Add(f);
}
if (files.Count == 0) Fail("열 수 있는 PDF가 없어요");
if (trim is { } t) foreach (var f in files) options = options.WithAdjustment(f.Path, t);

// 인쇄할 때는 프린터가 실제로 받아들이는 설정을 먼저 본다(양면이 안 되는 프린터면 단면으로 계산).
PrintPlan? printPlan = null;
if (doPrint)
{
    var printer = printerName ?? Printing.Printers().defaultName ?? Die<string>("프린터가 없어요 (--list-printers)");
    settings = settings with { Printer = printer };
    try { printPlan = Printing.Plan(settings); }
    catch (Exception ex) { Fail("인쇄하지 못했어요: " + ex.Message, 4); }
}
bool duplex = printPlan?.Duplex ?? settings.Duplex;

// 앱과 같은 규칙: 양면이면 홀수 쪽 파일 뒤에 빈 쪽, 양면으로 여러 부면 마지막 파일 뒤에도.
options = options with { PadSectionsToEven = duplex, PadEndToEven = duplex && settings.Copies > 1 };
var result = Imposer.Impose(files, options);
int sheets = duplex ? (result.PageCount + 1) / 2 : result.PageCount;

static double Mm(double pt) => Math.Round(pt / Units.PointsPerMM, 1);

if (json)
{
    var doc = new JsonObject
    {
        ["output_pages"] = result.PageCount,
        ["sheets"] = sheets,
        ["variant"] = options.Variant.Code(),
        ["paper_margin_mm"] = options.PaperMarginMM,
        ["files"] = new JsonArray(result.Sections.Select(s => (JsonNode)new JsonObject
        {
            ["path"] = s.File.Path,
            ["pages"] = s.File.PageCount,
            ["used_pages"] = new JsonArray(s.PageIndices.Select(i => (JsonNode)(i + 1)).ToArray()),
            ["both_variants"] = s.File.HasBothVariants,
            ["electives_in_file"] = new JsonArray(s.File.Electives.Select(e => (JsonNode)e.FullName()).ToArray()),
            ["elective"] = s.File.ElectiveSubject is { } sub && options.Electives.TryGetValue(sub, out var ch) ? ch.FullName() : null,
            ["page_size_mm"] = new JsonArray(Mm(s.PageSize.Width), Mm(s.PageSize.Height)),
            ["crop_margin_mm"] = new JsonObject
            {
                ["left"] = Mm(s.Crop.MinX), ["top"] = Mm(s.PageSize.Height - s.Crop.MaxY),
                ["right"] = Mm(s.PageSize.Width - s.Crop.MaxX), ["bottom"] = Mm(s.Crop.MinY),
            },
            ["scale"] = Math.Round(s.Scale, 4),
            ["blank_page_after"] = s.PadsBlankPage,
        }).ToArray()),
    };
    Console.WriteLine(doc.ToJsonString(new JsonSerializerOptions { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }));
}
else
{
    foreach (var s in result.Sections)
    {
        var tags = new List<string>();
        if (s.File.HasBothVariants) tags.Add("홀·짝 합본→" + options.Variant.Korean());
        if (s.File.ElectiveSubject is { } sub)
            tags.Add("선택과목→" + (options.Electives.TryGetValue(sub, out var ch) ? ch.ShortName() : $"전체({string.Join('·', s.File.Electives.Select(e => e.ShortName()))})"));
        if (s.PadsBlankPage) tags.Add("+빈 쪽");
        Console.WriteLine($"{s.File.Name}: {s.File.PageCount}쪽 → {s.PageIndices.Count}쪽, {Math.Round(s.Scale * 100)}%" +
            $"  (자른 여백 왼{(int)Mm(s.Crop.MinX)} 위{(int)Mm(s.PageSize.Height - s.Crop.MaxY)} 오{(int)Mm(s.PageSize.Width - s.Crop.MaxX)} 아래{(int)Mm(s.Crop.MinY)}mm)" +
            (tags.Count > 0 ? "  " + string.Join(", ", tags) : ""));
    }
    Console.WriteLine($"합계: A4 {result.PageCount}쪽, 종이 {sheets}장{(duplex ? " (양면)" : "")}");
}

if (output != null)
{
    try { File.WriteAllBytes(output, result.Pdf); } catch (Exception ex) { Fail("저장하지 못했어요: " + ex.Message); }
    if (!json) Console.WriteLine("저장: " + output);
}

if (doPrint)
{
    var printer = settings.Printer;
    var title = string.Join(", ", files.Select(f => f.Name));
    if (Printing.HardwareMarginMM(printer) is { } hw && options.PaperMarginMM + 0.05 < hw && !json)
        Console.WriteLine($"주의: 이 프린터는 가장자리 {hw:0.0}mm 안쪽만 찍혀요. --margin을 늘리는 게 좋아요.");
    try
    {
        if (dryRun)
        {
            Console.WriteLine("보낼 설정: " + printPlan!.Describe());
            return 0;
        }
        var plan = Printing.Print(result.Pdf, settings, title, printToFile);
        if (!json) Console.WriteLine("인쇄를 보냈어요: " + plan.Describe());
    }
    catch (Exception ex)
    {
        Fail("인쇄하지 못했어요: " + ex.Message, 4);
    }
}
return 0;
