import CoreGraphics
import Foundation

/// 수동 조정 화면의 위·아래 점선 계산. 좌표는 페이지 기준 pt(왼쪽 아래 원점, 화면 방향).
public enum CropGuides {
    public enum Edge: Sendable { case top, bottom }

    /// 두 점선 사이에 남겨야 하는 최소 높이(25mm). 내용이 사라질 만큼 좁히지 못하게 한다.
    public static let minGap: CGFloat = 25 * pointsPerMM

    /// 점선 하나를 y로 옮긴다. 페이지 밖으로 나가지 않고, 다른 점선과 minGap 이상 떨어진다.
    public static func move(_ edge: Edge, to y: CGFloat, top: CGFloat, bottom: CGFloat,
                            pageHeight: CGFloat, minGap: CGFloat = minGap) -> (top: CGFloat, bottom: CGFloat) {
        switch edge {
        case .top:
            return (min(pageHeight, max(y, bottom + minGap)), bottom)
        case .bottom:
            return (top, max(0, min(y, top - minGap)))
        }
    }

    /// 점선 위치를 손 조정 값으로 바꾼다. 위·아래만 바꾸고 좌우와 '자동 자르기 끄기'는 그대로 둔다.
    /// 값은 0.5mm 단위로 반올림한다. base는 손 조정 전 자동 범위(`Imposer.baseCrop`).
    public static func adjustment(top: CGFloat, bottom: CGFloat, base: CGRect,
                                  keeping old: CropAdjustment) -> CropAdjustment {
        func halfMM(_ pt: CGFloat) -> CGFloat { ((pt / pointsPerMM) * 2).rounded() / 2 }
        var a = old
        a.top = halfMM(base.maxY - top)
        a.bottom = halfMM(bottom - base.minY)
        return a
    }
}
