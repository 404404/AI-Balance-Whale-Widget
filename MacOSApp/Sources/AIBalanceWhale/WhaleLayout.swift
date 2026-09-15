import Cocoa

enum WhaleLayout {
    // Dimensions are CSS points in the standalone widget viewport. AppKit keeps
    // the screen anchor in the window frame; the WebView is never zoomed.
    static let baseWidth: CGFloat = CGFloat(WidgetLayoutModel.width)
    static let whaleHeight: CGFloat = CGFloat(WidgetLayoutModel.whaleHeight)
    static let compactHeight: CGFloat = CGFloat(WidgetLayoutModel.compactHeight)
    static let defaultBubbleHeight: CGFloat = 178
    static let maximumBubbleHeight: CGFloat = 250
    static let bubbleGap: CGFloat = CGFloat(WidgetLayoutModel.bubbleGap)
    static let baseSize = CGSize(width: baseWidth, height: compactHeight)
    static let baseWhaleRect = CGRect(x: 32, y: 10, width: 184, height: whaleHeight)
    static let minimumScale = WidgetLayoutModel.minimumScale
    static let maximumScale = WidgetLayoutModel.maximumScale

    static func scale(_ value: Double) -> CGFloat {
        CGFloat(min(max(value, minimumScale), maximumScale))
    }

    static func contentSize(scale value: Double, bubbleVisible: Bool = false, bubbleHeight: CGFloat = defaultBubbleHeight) -> CGSize {
        let size = WidgetLayoutModel.contentSize(scale: value, bubbleVisible: bubbleVisible, bubbleHeight: Double(bubbleHeight))
        return CGSize(width: size.width, height: size.height)
    }

    static func scaled(_ rect: CGRect, scale value: Double) -> CGRect {
        let factor = scale(value)
        return CGRect(x: rect.origin.x * factor, y: rect.origin.y * factor, width: rect.width * factor, height: rect.height * factor)
    }
}
