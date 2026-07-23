import CoreGraphics
import Testing

@testable import PanewrightCore

@Suite struct DropZoneTests {
    let frame = CGRect(x: 100, y: 100, width: 400, height: 200)

    @Test func centerOfFrameIsCenterZone() {
        #expect(DropZone.zone(at: CGPoint(x: 300, y: 200), in: frame) == .center)
    }

    @Test func edgeBandsResolveToEdges() {
        #expect(DropZone.zone(at: CGPoint(x: 120, y: 200), in: frame) == .left)
        #expect(DropZone.zone(at: CGPoint(x: 480, y: 200), in: frame) == .right)
        #expect(DropZone.zone(at: CGPoint(x: 300, y: 110), in: frame) == .top)
        #expect(DropZone.zone(at: CGPoint(x: 300, y: 290), in: frame) == .bottom)
    }

    @Test func cornersPickTheNearestEdge() {
        // 10px from the left, 30px from the top → left wins.
        #expect(DropZone.zone(at: CGPoint(x: 110, y: 130), in: frame) == .left)
        // 30px from the right edge (in x), 10px from the bottom → bottom wins
        // once normalized: 30/400 < 10/200 is false, so compare fractions.
        #expect(DropZone.zone(at: CGPoint(x: 470, y: 290), in: frame) == .bottom)
    }

    @Test func outsideFrameIsNil() {
        #expect(DropZone.zone(at: CGPoint(x: 50, y: 50), in: frame) == nil)
    }

    @Test func previewFramesHalveTheTarget() {
        #expect(
            DropZone.left.previewFrame(in: frame)
                == CGRect(x: 100, y: 100, width: 200, height: 200))
        #expect(
            DropZone.right.previewFrame(in: frame)
                == CGRect(x: 300, y: 100, width: 200, height: 200))
        #expect(
            DropZone.top.previewFrame(in: frame)
                == CGRect(x: 100, y: 100, width: 400, height: 100))
        #expect(
            DropZone.bottom.previewFrame(in: frame)
                == CGRect(x: 100, y: 200, width: 400, height: 100))
        #expect(DropZone.center.previewFrame(in: frame) == frame)
    }
}
