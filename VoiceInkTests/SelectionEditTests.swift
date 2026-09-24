import Foundation
import Testing
@testable import VoiceInk

struct SelectionEditTests {

    // MARK: - Capture decision

    private func capture(
        isEnabled: Bool = true,
        configured: Bool = true,
        selection: String? = "hello",
        role: String? = "AXTextArea",
        subrole: String? = nil,
        maxLength: Int = 100,
        bundleID: String? = "com.apple.TextEdit"
    ) -> SelectionEditContext? {
        SelectionEditService.captureDecision(
            isEnabled: isEnabled,
            isProviderConfigured: configured,
            selection: selection,
            focusedRole: role,
            focusedSubrole: subrole,
            maxInputLength: maxLength,
            frontmostBundleID: bundleID
        )
    }

    @Test func disabledMeansNoCapture() {
        #expect(capture(isEnabled: false) == nil)
    }

    @Test func unconfiguredProviderMeansNoCapture() {
        #expect(capture(configured: false) == nil)
    }

    @Test func nilSelectionMeansNoCapture() {
        #expect(capture(selection: nil) == nil)
    }

    @Test func emptySelectionMeansNoCapture() {
        #expect(capture(selection: "") == nil)
    }

    @Test func whitespaceSelectionMeansNoCapture() {
        #expect(capture(selection: "  \n\t ") == nil)
    }

    @Test func overLimitSelectionMeansNoCapture() {
        #expect(capture(selection: "abcdef", maxLength: 5) == nil)
    }

    @Test func atLimitCaptures() {
        #expect(capture(selection: "abcde", maxLength: 5)?.text == "abcde")
    }

    @Test func secureRoleMeansNoCapture() {
        #expect(capture(role: "AXSecureTextField") == nil)
        #expect(capture(subrole: "AXSecureTextField") == nil)
    }

    @Test func normalCaptureCarriesTextAndBundle() {
        #expect(capture() == SelectionEditContext(text: "hello", bundleID: "com.apple.TextEdit"))
    }

    // MARK: - Paste decision

    private let context = SelectionEditContext(text: "вторник", bundleID: "com.apple.TextEdit")

    @Test func sameAppSameTextPastes() {
        #expect(
            SelectionEditService.pasteDecision(
                context: context,
                frontmostBundleID: "com.apple.TextEdit",
                currentSelection: "вторник"
            ) == .paste
        )
    }

    @Test func differentAppGoesToClipboard() {
        #expect(
            SelectionEditService.pasteDecision(
                context: context,
                frontmostBundleID: "com.google.Chrome",
                currentSelection: "вторник"
            ) == .clipboard
        )
    }

    @Test func changedTextGoesToClipboard() {
        #expect(
            SelectionEditService.pasteDecision(
                context: context,
                frontmostBundleID: "com.apple.TextEdit",
                currentSelection: "среда"
            ) == .clipboard
        )
    }

    @Test func unreadableSelectionGoesToClipboard() {
        #expect(
            SelectionEditService.pasteDecision(
                context: context,
                frontmostBundleID: "com.apple.TextEdit",
                currentSelection: nil
            ) == .clipboard
        )
        #expect(
            SelectionEditService.pasteDecision(
                context: context,
                frontmostBundleID: nil,
                currentSelection: "вторник"
            ) == .clipboard
        )
    }

    // MARK: - User message

    @Test func userMessageKeepsBlocksApart() {
        let message = SelectionEditService.makeUserMessage(selectedText: "SEL", spokenText: "SPK")
        #expect(message.contains("<SELECTED_TEXT>\nSEL\n</SELECTED_TEXT>"))
        #expect(message.contains("<TRANSCRIPT>\nSPK\n</TRANSCRIPT>"))
        let selectedRange = message.range(of: "SEL")!
        let transcriptHeader = message.range(of: "<TRANSCRIPT>")!
        let spokenRange = message.range(of: "SPK")!
        #expect(selectedRange.upperBound < transcriptHeader.lowerBound)
        #expect(transcriptHeader.upperBound < spokenRange.lowerBound)
    }
}
