import Cocoa

enum WhaleLayout {
    static let baseSize = CGSize(width: 248, height: 410)
    static let baseWhaleRect = CGRect(x: 32, y: 230, width: 184, height: 173)
    static let minimumScale = 0.65
    static let maximumScale = 1.6

    static func scale(_ value: Double) -> CGFloat {
        CGFloat(min(max(value, minimumScale), maximumScale))
    }

    static func contentSize(scale value: Double) -> CGSize {
        let factor = scale(value)
        return CGSize(width: baseSize.width * factor, height: baseSize.height * factor)
    }

    static func scaled(_ rect: CGRect, scale value: Double) -> CGRect {
        let factor = scale(value)
        return CGRect(x: rect.origin.x * factor, y: rect.origin.y * factor, width: rect.width * factor, height: rect.height * factor)
    }
}
