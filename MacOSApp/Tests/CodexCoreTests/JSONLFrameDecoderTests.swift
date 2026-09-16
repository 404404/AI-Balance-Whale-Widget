import Foundation
import XCTest
@testable import CodexCore

final class JSONLFrameDecoderTests: XCTestCase {
    func testFramesCanBeSplitAndCoalesced() throws {
        var decoder = JSONLFrameDecoder()
        XCTAssertEqual(decoder.append(Data("{\"id\":1".utf8)), [])
        let first = decoder.append(Data("}\n{\"id\":2}\n{\"id\":".utf8))
        XCTAssertEqual(first, [Data("{\"id\":1}".utf8), Data("{\"id\":2}".utf8)])
        XCTAssertEqual(decoder.append(Data("3}\r\n".utf8)), [Data("{\"id\":3}".utf8)])
    }

    func testResetDropsPartialFrame() {
        var decoder = JSONLFrameDecoder()
        _ = decoder.append(Data("{\"stale\":true}".utf8))
        decoder.reset()
        XCTAssertEqual(decoder.append(Data("{\"fresh\":true}\n".utf8)), [Data("{\"fresh\":true}".utf8)])
    }
}
