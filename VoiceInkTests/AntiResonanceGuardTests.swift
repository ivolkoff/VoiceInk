import Testing
@testable import VoiceInk

struct AntiResonanceGuardTests {
    @Test func normalTypingIsAllowed() {
        let g = AntiResonanceGuard()
        var now = 0.0
        g.clock = { now }
        #expect(g.allow(word: "ghbdtn", produced: "привет"))
        now += 1
        #expect(g.allow(word: "vbh", produced: "мир"))
    }

    @Test func oscillationFreezes() {
        let g = AntiResonanceGuard()
        var now = 0.0
        g.clock = { now }
        #expect(g.allow(word: "ghbdtn", produced: "привет"))
        now += 0.1
        #expect(!g.allow(word: "привет", produced: "ghbdtn"))
        #expect(g.isFrozen)
        now += 0.1
        #expect(!g.allow(word: "vbh", produced: "мир"))
        now += 3
        #expect(!g.isFrozen)
        #expect(g.allow(word: "vbh", produced: "мир"))
    }

    @Test func stormFreezes() {
        let g = AntiResonanceGuard(window: 1, maxFlips: 3, freezeFor: 5)
        var now = 0.0
        g.clock = { now }
        for i in 0..<3 {
            #expect(g.allow(word: "w\(i)", produced: "p\(i)"))
            now += 0.1
        }
        #expect(!g.allow(word: "w9", produced: "p9"))
    }
}
