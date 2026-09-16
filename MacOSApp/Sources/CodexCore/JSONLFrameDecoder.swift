import Foundation

/// Incremental decoder for the app-server's newline-delimited JSON transport.
/// It intentionally does not parse JSON; callers can associate each complete
/// frame with a request while this type handles arbitrary read boundaries.
public struct JSONLFrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            let frame = line.last == 13 ? line.dropLast() : line[...]
            if !frame.isEmpty { frames.append(Data(frame)) }
        }
        return frames
    }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
    }
}
