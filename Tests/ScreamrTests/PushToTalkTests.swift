import Testing
@testable import Screamr

@Test func longHoldFinishesOnRelease() {
    var p = PushToTalk()
    let down = p.fnDown(at: 0), up = p.fnUp(at: 1.2)
    #expect(down == .start)
    #expect(up == .finish)
    #expect(!p.isActive)
}

@Test func loneTapIsCancelledAfterWindow() {
    var p = PushToTalk()
    _ = p.fnDown(at: 0)
    let up = p.fnUp(at: 0.1), early = p.tick(at: 0.3), late = p.tick(at: 0.6)
    #expect(up == .none)
    #expect(early == .none)
    #expect(late == .cancel)
    #expect(!p.isActive)
}

@Test func doubleTapLocksUntilNextPress() {
    var p = PushToTalk()
    _ = p.fnDown(at: 0)
    _ = p.fnUp(at: 0.1)
    let lock = p.fnDown(at: 0.3), up = p.fnUp(at: 0.4), tick = p.tick(at: 5), end = p.fnDown(at: 9)
    #expect(lock == .lock)
    #expect(up == .none)
    #expect(tick == .none)
    #expect(end == .finish)
}

@Test func fnSpaceLocksAndEscapeCancels() {
    var p = PushToTalk()
    let idleSpace = p.space()
    _ = p.fnDown(at: 0)
    let space = p.space(), up = p.fnUp(at: 0.2), esc = p.escape(), idleEsc = p.escape()
    #expect(!idleSpace)
    #expect(space)
    #expect(up == .none)
    #expect(esc)
    #expect(!idleEsc)
    #expect(!p.isActive)
}
