import CoreGraphics
import Testing
@testable import Screamr

@Test func meetingVideoRoundTrips() {
    for video in [MeetingVideo.none, .screen, .app(bundleID: "us.zoom.xos", name: "zoom.us"), .app(bundleID: "a.b", name: "Notes: draft")] {
        #expect(MeetingVideo(video.stored) == video)
    }
}

@Test func meetingVideoGarbageFallsBackToNone() {
    for text in ["", "video", "screen:extra", "app", "app:", "app::Name", "app:only.id"] {
        #expect(MeetingVideo(text) == .none)
    }
}

@Test func meetingVideoSizeIsEvenAndCapped() {
    let (w, h) = MeetingVideo.captureSize(points: CGSize(width: 1512, height: 982), scale: 2)
    #expect(w == 1920 && h % 2 == 0 && w % 2 == 0)
}
