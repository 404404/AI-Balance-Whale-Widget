import Foundation

public enum WidgetLayoutModel {
    public static let width: Double = 248
    public static let whaleHeight: Double = 174
    public static let compactHeight: Double = 184
    public static let bubbleGap: Double = 6
    public static let minimumScale: Double = 0.65
    public static let maximumScale: Double = 1.6

    public static func clampedScale(_ value: Double) -> Double {
        min(max(value, minimumScale), maximumScale)
    }

    public static func baseHeight(bubbleVisible: Bool, bubbleHeight: Double) -> Double {
        guard bubbleVisible else { return compactHeight }
        return whaleHeight + bubbleGap + min(max(bubbleHeight, 120), 250)
    }

    public static func contentSize(scale: Double, bubbleVisible: Bool, bubbleHeight: Double) -> (width: Double, height: Double) {
        let factor = clampedScale(scale)
        return (width * factor, baseHeight(bubbleVisible: bubbleVisible, bubbleHeight: bubbleHeight) * factor)
    }

    /// Returns the new AppKit origin that keeps the window bottom edge fixed.
    /// NSWindow uses a bottom-left origin, so resizing upward does not add the
    /// old height or subtract the new height.
    public static func preservedBottomOrigin(oldMinY: Double, oldHeight: Double, newHeight: Double) -> Double {
        oldMinY
    }
}

public struct BubbleQueueModel: Equatable {
    public let advanceOnClick: Bool
    public let againAction: String
    public let count: Int
    public private(set) var index: Int = 0
    public private(set) var visible: Bool = false

    public init(count: Int, advanceOnClick: Bool = true, againAction: String = "toggle") {
        self.count = max(0, count)
        self.advanceOnClick = advanceOnClick
        self.againAction = againAction
    }

    public mutating func clickWhale() {
        guard count > 0 else { visible = true; return }
        if !visible { index = 0; visible = true; return }
        guard advanceOnClick else {
            if againAction == "toggle" { visible = false }
            return
        }
        index += 1
        if index >= count {
            index = 0
            visible = false
        }
    }
}
