import Testing
@testable import VoiceInk

struct KeystrokeBufferTests {
    private func key(_ code: UInt16) -> TypedKey { TypedKey(keyCode: code, shift: false, caps: false) }

    @Test func spaceCompletesCurrentWord() {
        var b = KeystrokeBuffer()
        b.append(key(5)); b.append(key(4))
        let completed = b.space()
        #expect(completed == [key(5), key(4)])
        #expect(b.currentWord.isEmpty)
        #expect(b.previousWord == [key(5), key(4)])
        #expect(b.boundaryCount == 1)
    }

    @Test func extraSpacesExtendTheBoundary() {
        var b = KeystrokeBuffer()
        b.append(key(5)); _ = b.space()
        #expect(b.space() == nil)
        #expect(b.boundaryCount == 2)
        #expect(b.manualTarget?.keys == [key(5)])
        #expect(b.manualTarget?.trailingSpaces == 2)
    }

    @Test func newLetterForgetsPreviousWord() {
        var b = KeystrokeBuffer()
        b.append(key(5)); _ = b.space(); b.append(key(4))
        #expect(b.previousWord.isEmpty)
        #expect(b.boundaryCount == 0)
        #expect(b.manualTarget?.keys == [key(4)])
        #expect(b.manualTarget?.trailingSpaces == 0)
    }

    @Test func backspaceInsideWordDropsLastKey() {
        var b = KeystrokeBuffer()
        b.append(key(5)); b.append(key(4))
        let droppedInside = b.backspace()
        #expect(droppedInside)
        #expect(b.currentWord == [key(5)])
    }

    @Test func backspaceAcrossBoundaryResets() {
        var b = KeystrokeBuffer()
        b.append(key(5)); _ = b.space()
        let droppedAcross = b.backspace()
        #expect(!droppedAcross)
        #expect(b.manualTarget == nil)
    }

    @Test func skippedWordIsIgnoredUntilTheNextSpace() {
        var b = KeystrokeBuffer()
        b.append(key(5)); b.skipWord(); b.append(key(4))
        b.backspace()
        #expect(b.manualTarget == nil)
        #expect(b.space() == nil)
        b.append(key(3))
        #expect(b.manualTarget?.keys == [key(3)])
    }

    @Test func leadingSpacesAreNotABoundary() {
        var b = KeystrokeBuffer()
        let leading = b.space()
        #expect(leading == nil)
        #expect(b.boundaryCount == 0)
        #expect(b.manualTarget == nil)
    }
}
