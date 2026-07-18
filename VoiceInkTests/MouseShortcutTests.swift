//
//  MouseShortcutTests.swift
//  VoiceInkTests
//

import AppKit
import Testing
@testable import VoiceInk

struct MouseShortcutTests {

    @Test func codableRoundTripPreservesButtonAndModifiers() throws {
        let shortcut = Shortcut.mouseButton(button: 3, modifierFlags: [.command])
        let data = try JSONEncoder().encode(shortcut)
        let decoded = try JSONDecoder().decode(Shortcut.self, from: data)

        #expect(decoded == shortcut)
        #expect(decoded.isMouseButton)
        #expect(decoded.mouseButton == 3)
        #expect(decoded.modifierFlags == [.command])
    }

    @Test func matchesOnlyExactButtonAndModifiers() {
        let shortcut = Shortcut.mouseButton(button: 2, modifierFlags: [.command])

        #expect(shortcut.matchesMouseEvent(button: 2, modifierFlags: [.command]))
        #expect(!shortcut.matchesMouseEvent(button: 2, modifierFlags: []))
        #expect(!shortcut.matchesMouseEvent(button: 3, modifierFlags: [.command]))
    }

    @Test func bareMiddleClickMatchesWithoutModifiers() {
        let shortcut = Shortcut.mouseButton(button: 2, modifierFlags: [])

        #expect(shortcut.matchesMouseEvent(button: 2, modifierFlags: []))
        #expect(!shortcut.matchesMouseEvent(button: 2, modifierFlags: [.command]))
    }

    @Test func conflictsWithSameButtonOnly() {
        let middle = Shortcut.mouseButton(button: 2, modifierFlags: [])

        #expect(middle.conflicts(with: .mouseButton(button: 2, modifierFlags: [])))
        #expect(!middle.conflicts(with: .mouseButton(button: 3, modifierFlags: [])))
        // Different kind never conflicts.
        #expect(!middle.conflicts(with: .key(keyCode: 0, modifierFlags: [.command])))
    }

    @Test func displayTokens() {
        #expect(Shortcut.mouseButton(button: 2, modifierFlags: []).displayTokens == ["Middle Click"])
        #expect(Shortcut.mouseButton(button: 3, modifierFlags: []).displayTokens == ["Mouse 4"])
        #expect(Shortcut.mouseButton(button: 2, modifierFlags: [.command]).displayTokens == ["⌘", "Middle Click"])
    }
}
