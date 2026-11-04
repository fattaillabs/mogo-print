import CoreGraphics
import Foundation

/// 여백 수동 조정 화면의 네 변 점선 계산. 좌표는 페이지 기준 pt(왼쪽 아래 원점, 화면 방향).
public enum CropGuides {
    public enum Edge: Sendable, CaseIterable { case top, bottom, left, right }

    /// 마주 보는 두 점선 사이에 남겨야 하는 최소 길이(25mm). 내용이 사라질 만큼 좁히지 못하게 한다.
    public static let minGap: CGFloat = 25 * pointsPerMM

    /// 점선 하나를 옮긴다(위·아래는 y, 왼쪽·오른쪽은 x). 페이지 밖으로 나가지 않고,
    /// 마주 보는 점선과 minGap 이상 떨어진다. 나머지 세 변은 그대로 둔다.
    public static func move(_ edge: Edge, to value: CGFloat, crop c: CGRect, pageSize page: CGSize,
                            minGap: CGFloat = minGap) -> CGRect {
        var minX = c.minX, maxX = c.maxX, minY = c.minY, maxY = c.maxY
        switch edge {
        case .top: maxY = min(page.height, max(value, minY + minGap))
        case .bottom: minY = max(0, min(value, maxY - minGap))
        case .left: minX = max(0, min(value, maxX - minGap))
        case .right: maxX = min(page.width, max(value, minX + minGap))
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 점선으로 정한 범위를 손 조정 값으로 바꾼다. '자동 자르기 끄기'는 그대로 둔다.
    /// 값은 0.5mm 단위로 반올림한다. base는 손 조정 전 자동 범위(`Imposer.baseCrop`).
    public static func adjustment(crop c: CGRect, base: CGRect, keeping old: CropAdjustment) -> CropAdjustment {
        func halfMM(_ pt: CGFloat) -> CGFloat { ((pt / pointsPerMM) * 2).rounded() / 2 }
        var a = old
        a.top = halfMM(base.maxY - c.maxY)
        a.bottom = halfMM(c.minY - base.minY)
        a.left = halfMM(c.minX - base.minX)
        a.right = halfMM(base.maxX - c.maxX)
        return a
    }
}
