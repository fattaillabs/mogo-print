// 설명·시험용 예시 문제지를 만든다. 실제 평가원 시험지는 저작권 때문에 저장소에 넣을 수 없어서,
// 판형(A3)·여백·홀짝 표시만 수능 문제지를 흉내 낸 가짜 문제지를 그린다. 글은 모두 이 저장소에서 새로 쓴 것이다.
//
//     swift Tools/make-demo.swift ../docs/demo
import AppKit
import CoreText

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".", isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let mm = 72.0 / 25.4
let pageSize = CGSize(width: 841.89, height: 1190.55) // A3
// 실제 수능 문제지와 비슷한 바깥 여백(mm): 왼쪽 29, 위 37, 오른쪽 25, 아래 25
let content = CGRect(x: 29 * mm, y: 25 * mm, width: pageSize.width - 54 * mm, height: pageSize.height - 62 * mm)

func font(_ name: String, _ size: CGFloat) -> CTFont { CTFontCreateWithName(name as CFString, size, nil) }
let serif = "AppleMyungjo", sansBold = "AppleSDGothicNeo-Bold", sans = "AppleSDGothicNeo-Regular"

func paragraphStyle(_ align: CTTextAlignment, _ spacing: CGFloat) -> CTParagraphStyle {
    var a = align, s = spacing
    return withUnsafeBytes(of: &a) { ap in
        withUnsafeBytes(of: &s) { sp in
            let settings = [
                CTParagraphStyleSetting(spec: .alignment, valueSize: ap.count, value: ap.baseAddress!),
                CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: sp.count, value: sp.baseAddress!),
            ]
            return CTParagraphStyleCreate(settings, settings.count)
        }
    }
}

func attributed(_ text: String, _ f: CTFont, lineSpacing: CGFloat = 0, align: CTTextAlignment = .justified) -> CFAttributedString {
    let style = paragraphStyle(align, lineSpacing)
    let attrs = [kCTFontAttributeName: f, kCTParagraphStyleAttributeName: style,
                 kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1)] as [CFString: Any]
    return CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)
}

/// 글을 상자 안에 흘려 쓰고, 실제로 쓴 높이를 돌려준다.
@discardableResult
func draw(_ text: String, in rect: CGRect, _ ctx: CGContext, font f: CTFont, lineSpacing: CGFloat = 5,
          align: CTTextAlignment = .justified) -> CGFloat {
    let setter = CTFramesetterCreateWithAttributedString(attributed(text, f, lineSpacing: lineSpacing, align: align))
    let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil,
                                                          CGSize(width: rect.width, height: .greatestFiniteMagnitude), nil)
    let h = min(rect.height, ceil(fit.height))
    let path = CGPath(rect: CGRect(x: rect.minX, y: rect.maxY - h, width: rect.width, height: h), transform: nil)
    CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(), path, nil), ctx)
    return h
}

/// 한 줄 글자를 상자 한가운데에 그린다(상자가 줄 높이보다 낮아도 그려진다).
func drawCentered(_ text: String, in rect: CGRect, _ ctx: CGContext, font f: CTFont) {
    let l = CTLineCreateWithAttributedString(attributed(text, f, align: .center))
    var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
    let w = CGFloat(CTLineGetTypographicBounds(l, &ascent, &descent, &leading))
    ctx.textPosition = CGPoint(x: rect.midX - w / 2, y: rect.midY - (ascent - descent) / 2)
    CTLineDraw(l, ctx)
}

func line(_ ctx: CGContext, _ a: CGPoint, _ b: CGPoint, width: CGFloat = 1) {
    ctx.setLineWidth(width); ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
}

let passages = [
    "종이의 크기는 나라와 시대에 따라 제각각이었으나, 오늘날 널리 쓰이는 A판 규격은 가로와 세로의 비가 1 대 √2로 정해져 있다. 이 비율의 종이는 긴 변을 반으로 접어도 처음과 같은 모양이 된다는 특징이 있다. 그래서 A3 종이를 반으로 자르면 A4 두 장이 되고, A4를 다시 반으로 자르면 A5가 된다. 같은 내용을 한 단계 작은 종이에 옮길 때 가로와 세로를 같은 비율로 줄이기만 하면 모양이 흐트러지지 않는 것도 이 때문이다.",
    "그런데 같은 비율로 줄이기만 하면 글자도 함께 작아진다. A3를 A4에 그대로 옮기면 길이가 약 71퍼센트로 줄어드는데, 본래 넉넉하게 잡혀 있던 바깥 여백까지 그대로 줄어들어 종이의 상당 부분이 빈칸으로 남는다. 이때 내용이 없는 바깥 여백을 먼저 잘라 내고 남은 부분을 종이에 꽉 차게 놓으면 같은 A4 안에서도 글자를 더 크게 담을 수 있다. 다만 프린터마다 종이 가장자리에서 찍을 수 없는 좁은 띠가 있으므로 그만큼은 비워 두어야 한다.",
    "양면 인쇄는 종이를 아끼는 방법이면서 시험지를 실제와 비슷하게 만드는 방법이기도 하다. 책처럼 긴 쪽을 기준으로 넘기려면 뒷면의 위아래가 앞면과 같은 방향이어야 하는데, 프린터는 종이를 뒤집는 방식에 따라 뒷면을 거꾸로 돌려 받기도 한다. 이런 차이는 보통 운영 체제의 인쇄 시스템이 프린터가 알려 주는 정보를 보고 맞춰 준다. 한편 과목마다 쪽수가 홀수이면 다음 과목이 앞 과목의 마지막 장 뒷면에서 시작하게 되므로, 빈 쪽을 하나 끼워 넣어 새 종이에서 시작하게 하는 것이 좋다.",
    "시험지를 집에서 뽑을 때 흑백으로 인쇄하면 컬러 잉크를 아낄 수 있다. 문제지는 대부분 검은 글자와 회색 도형으로 되어 있어 흑백으로 뽑아도 읽는 데 지장이 없다. 다만 일부 프린터는 흑백으로 설정해도 검은색을 여러 색 잉크를 섞어 만들기도 하므로, 드라이버가 제공하는 회색조 설정을 함께 고르는 것이 확실하다.",
]
let questions = [
    ("윗글의 내용과 일치하는 것은?", ["A판 종이는 가로와 세로의 길이가 같다.", "A3 종이를 반으로 자르면 A5 두 장이 된다.", "같은 비율로 줄이면 글자 크기는 변하지 않는다.", "바깥 여백을 자르면 같은 종이에 글자를 더 크게 담을 수 있다.", "프린터는 종이 가장자리 끝까지 모두 찍을 수 있다."]),
    ("윗글을 바탕으로 추론한 내용으로 적절하지 않은 것은?", ["A4를 반으로 자른 종이도 1 대 √2의 비를 가진다.", "여백을 남기지 않으면 가장자리 글자가 찍히지 않을 수 있다.", "쪽수가 홀수인 과목 뒤에는 빈 쪽이 필요할 수 있다.", "양면 인쇄에서 뒷면 방향은 언제나 사용자가 직접 돌려야 한다.", "흑백 인쇄는 컬러 잉크를 아끼는 데 도움이 된다."]),
    ("윗글의 ㉠에 대한 설명으로 가장 적절한 것은?", ["종이의 모양을 바꾸어 글자를 키운다.", "내용이 없는 부분을 잘라 종이를 더 넓게 쓴다.", "줄이는 비율을 가로와 세로에 다르게 적용한다.", "인쇄할 수 없는 띠를 없애는 방법이다.", "양면 인쇄의 방향을 정하는 방법이다."]),
]

/// 쪽 머리말. 선택과목 쪽이면 제목 아래에 "(화법과 작문)"처럼 과목명을 괄호로 찍는다(실제 시험지와 같은 방식).
/// 돌려주는 값은 본문이 시작하는 높이.
@discardableResult
func header(_ ctx: CGContext, subject: String, variant: String, page: Int, total: Int, first: Bool,
            elective: String? = nil) -> CGFloat {
    let top = content.maxY
    draw("2027학년도 모고 프린트 예시 문제지", in: CGRect(x: content.minX, y: top - 28, width: content.width, height: 28),
         ctx, font: font(sans, 20), lineSpacing: 0, align: .center)
    draw("\(page)", in: CGRect(x: content.maxX - 60, y: top - 46, width: 60, height: 46), ctx,
         font: font("Times New Roman Bold", 40), lineSpacing: 0, align: .right)
    let titleSize: CGFloat = first ? 46 : 30
    let titleY = top - (first ? 92 : 74)
    draw(subject, in: CGRect(x: content.minX, y: titleY, width: content.width, height: titleSize + 12), ctx,
         font: font(sansBold, titleSize), lineSpacing: 0, align: .center)
    if first {
        let oval = CGRect(x: content.minX, y: titleY + 8, width: 110, height: 40)
        ctx.setLineWidth(1.5); ctx.strokeEllipse(in: oval)
        drawCentered("제 1 교시", in: oval, ctx, font: font(sansBold, 18))
    }
    let box = CGRect(x: content.maxX - (first ? 120 : 96), y: titleY + 6, width: first ? 120 : 96, height: first ? 46 : 36)
    ctx.setLineWidth(2); ctx.stroke(box)
    drawCentered(variant, in: box, ctx, font: font(sansBold, first ? 24 : 18))
    var ruleY = titleY - 8
    if let elective {
        drawCentered("(\(elective))", in: CGRect(x: content.minX, y: titleY - 34, width: content.width, height: 24),
                     ctx, font: font(sansBold, 20))
        ruleY -= 30
    }
    line(ctx, CGPoint(x: content.minX, y: ruleY), CGPoint(x: content.maxX, y: ruleY), width: 2)
    // 아래쪽: 쪽 번호 상자와 안내 문구
    let pageBox = CGRect(x: pageSize.width / 2 - 30, y: content.minY + 4, width: 60, height: 26)
    ctx.setLineWidth(1); ctx.stroke(pageBox)
    drawCentered("\(page) / \(total)", in: pageBox, ctx, font: font(sans, 14))
    draw("설명용 예시 문제지 · 실제 시험과 관계없음",
         in: CGRect(x: content.maxX - 220, y: content.minY, width: 220, height: 16), ctx,
         font: font(sans, 10), lineSpacing: 0, align: .right)
    return ruleY - 12
}

/// 공통 과목 마지막 쪽 등에 들어가는 확인 사항 상자. 다음 선택과목을 안내한다.
func notice(_ ctx: CGContext, next: String, column x: CGFloat, width: CGFloat) {
    let text = "※ 확인 사항\n◦ 답안지의 해당란에 필요한 내용을 정확히 기입(표기)했는지 확인하시오.\n◦ 이어서, 「선택과목(\(next))」 문제가 제시되오니, 자신이 선택한 과목인지 확인하시오."
    let rect = CGRect(x: x, y: content.minY + 48, width: width, height: 116)
    ctx.setLineWidth(1); ctx.stroke(rect)
    draw(text, in: rect.insetBy(dx: 10, dy: 8), ctx, font: font(serif, 12), lineSpacing: 4, align: .left)
}

/// 국어형 쪽: 두 단, 지문 상자 + 문항.
func koreanPage(_ ctx: CGContext, page: Int, variant: String, total: Int, seed: Int,
                elective: String? = nil, next: String? = nil) {
    // 문항 번호는 쪽마다 이어진다(1쪽: 1~4번, 2쪽: 5~8번 …).
    let top = header(ctx, subject: "국어 영역", variant: variant, page: page, total: total,
                     first: page == 1 || elective != nil, elective: elective) + 6
    let gap: CGFloat = 26
    let colW = (content.width - gap) / 2
    line(ctx, CGPoint(x: content.midX, y: top), CGPoint(x: content.midX, y: content.minY + 40), width: 1)
    for col in 0..<2 {
        let x = content.minX + CGFloat(col) * (colW + gap)
        var y = top - 6
        let q = (seed + col) % questions.count
        let first = ((page - 1) * 2 + col) * 2 + 1
        y -= draw("[\(first)～\(first + 1)] 다음 글을 읽고 물음에 답하시오.", in: CGRect(x: x, y: y - 40, width: colW, height: 40),
                  ctx, font: font(serif, 13), lineSpacing: 2, align: .left) + 8
        let text = (0..<2).map { passages[(seed + col + $0) % passages.count] }.joined(separator: "\n　")
        let passageRect = CGRect(x: x + 10, y: content.minY + 430, width: colW - 20, height: y - 12 - (content.minY + 430))
        let used = draw("　" + text, in: passageRect, ctx, font: font(serif, 13), lineSpacing: 6)
        ctx.setLineWidth(1); ctx.stroke(CGRect(x: x, y: y - used - 18, width: colW, height: used + 12))
        y -= used + 34
        // 안내 상자가 들어가는 오른쪽 단은 문항을 하나만 둔다.
        for k in 0..<(next != nil && col == 1 ? 1 : 2) {
            let (stem, choices) = questions[(q + k) % questions.count]
            y -= draw("\(first + k). \(stem)", in: CGRect(x: x, y: y - 40, width: colW, height: 40), ctx,
                      font: font(serif, 13.5), lineSpacing: 2, align: .left) + 8
            for (i, c) in choices.enumerated() {
                y -= draw("\(["①", "②", "③", "④", "⑤"][i]) \(c)", in: CGRect(x: x + 8, y: y - 34, width: colW - 8, height: 34),
                          ctx, font: font(serif, 13), lineSpacing: 2, align: .left) + 5
            }
            y -= 24
        }
    }
    if let next { notice(ctx, next: next, column: content.minX + colW + gap, width: colW) }
}

/// 수학형 쪽: 두 단, 문항 사이를 넓게 비운다.
func mathPage(_ ctx: CGContext, page: Int, total: Int, elective: String? = nil, next: String? = nil) {
    let top = header(ctx, subject: "수학 영역", variant: "홀수형", page: page, total: total,
                     first: page == 1 || elective != nil, elective: elective) + 4
    let gap: CGFloat = 26
    let colW = (content.width - gap) / 2
    line(ctx, CGPoint(x: content.midX, y: top), CGPoint(x: content.midX, y: content.minY + 40), width: 1)
    let problems = [
        // 위·아래 첨자는 명조 글꼴에 없어 깨지므로 일반 문자로만 쓴다.
        ("3 × 4 + 2 × 6 의 값은? [2점]", "① 18　　② 20　　③ 22　　④ 24　　⑤ 26"),
        ("함수 f(x) = 2x + 5 에 대하여 f(3) 의 값은? [2점]", "① 7　　② 9　　③ 11　　④ 13　　⑤ 15"),
        ("첫째항이 3, 공차가 3인 등차수열의 제10항의 값은? [3점]", "① 27　　② 30　　③ 33　　④ 36　　⑤ 39"),
        ("x = 2 일 때, (x + 1)(x + 3) 의 값은? [2점]", "① 12　　② 15　　③ 18　　④ 21　　⑤ 24"),
    ]
    for col in 0..<2 {
        let x = content.minX + CGFloat(col) * (colW + gap)
        for k in 0..<2 {
            let n = (page - 1) * 4 + col * 2 + k
            let (stem, choices) = problems[n % problems.count]
            var y = top - 10 - CGFloat(k) * (top - content.minY - 60) / 2
            y -= draw("\(n + 1). \(stem)", in: CGRect(x: x, y: y - 40, width: colW, height: 40), ctx,
                      font: font(serif, 15), lineSpacing: 2, align: .left) + 14
            draw(choices, in: CGRect(x: x + 8, y: y - 30, width: colW - 8, height: 30), ctx,
                 font: font(serif, 14), lineSpacing: 0, align: .left)
        }
    }
    if let next { notice(ctx, next: next, column: content.minX + colW + gap, width: colW) }
}

func makePDF(_ name: String, pages: Int, _ body: (CGContext, Int) -> Void) {
    let url = outDir.appendingPathComponent(name)
    var box = CGRect(origin: .zero, size: pageSize)
    let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
    for p in 1...pages {
        ctx.beginPDFPage(nil)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        body(ctx, p)
        ctx.endPDFPage()
    }
    ctx.closePDF()
    print(url.path)
}

// 국어: 홀수형 4쪽 + 짝수형 4쪽이 한 파일에 든 합본. 형마다 공통 2쪽, 화법과 작문 1쪽, 언어와 매체 1쪽.
makePDF("예시_국어_문제지.pdf", pages: 8) { ctx, p in
    let k = (p - 1) % 4 + 1
    let variant = p <= 4 ? "홀수형" : "짝수형"
    switch k {
    case 1: koreanPage(ctx, page: 1, variant: variant, total: 4, seed: p)
    case 2: koreanPage(ctx, page: 2, variant: variant, total: 4, seed: p, next: "화법과 작문")
    case 3: koreanPage(ctx, page: 3, variant: variant, total: 4, seed: p, elective: "화법과 작문", next: "언어와 매체")
    default: koreanPage(ctx, page: 4, variant: variant, total: 4, seed: p, elective: "언어와 매체")
    }
}
// 수학: 공통 2쪽, 확률과 통계·미적분·기하 1쪽씩(5쪽). 선택과목 하나만 고르면 3쪽이라 양면 인쇄 때 빈 쪽이 들어간다.
makePDF("예시_수학_문제지.pdf", pages: 5) { ctx, p in
    let electives = ["확률과 통계", "미적분", "기하"]
    switch p {
    case 1: mathPage(ctx, page: 1, total: 5)
    case 2: mathPage(ctx, page: 2, total: 5, next: electives[0])
    default: mathPage(ctx, page: p, total: 5, elective: electives[p - 3], next: p < 5 ? electives[p - 2] : nil)
    }
}
