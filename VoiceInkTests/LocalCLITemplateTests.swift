import Foundation
import Testing
@testable import VoiceInk

struct LocalCLITemplateTests {
    /// Runs the built-in Claude template the way LocalCLIService does (zsh, VOICEINK_* env,
    /// full prompt on stdin) against a fake `claude` that records its argv and stdin.
    @Test func claudeTemplatePassesSystemPromptAsArgumentAndUserPromptOnStdin() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fake = dir.appendingPathComponent("claude")
        try """
        #!/bin/sh
        for a in "$@"; do printf '%s\\0' "$a"; done > "$OUT/args"
        cat > "$OUT/stdin"
        printf '%s' "$CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" > "$OUT/traffic"
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let systemPrompt = "Line \"one\"\n$HOME 'two' `x`"
        let userPrompt = "\n<TRANSCRIPT>\nпривет\n</TRANSCRIPT>"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", LocalCLITemplate.claude.commandTemplate]
        process.environment = [
            "PATH": "\(dir.path):/usr/bin:/bin",
            "OUT": dir.path,
            "VOICEINK_SYSTEM_PROMPT": systemPrompt,
            "VOICEINK_USER_PROMPT": userPrompt,
            "VOICEINK_FULL_PROMPT": "full prompt must not reach claude",
        ]
        let stdin = Pipe()
        process.standardInput = stdin
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: Data("full prompt must not reach claude".utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let argsData = try Data(contentsOf: dir.appendingPathComponent("args"))
        let args = argsData.split(separator: 0, omittingEmptySubsequences: false).dropLast()
            .map { String(decoding: $0, as: UTF8.self) }
        func value(after flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }

        #expect(args.contains("-p"))
        #expect(value(after: "--system-prompt") == systemPrompt)
        #expect(value(after: "--model") == "claude-sonnet-5-5")
        #expect(value(after: "--fallback-model") == "claude-haiku-5-5")
        #expect(args.contains("--tools="))
        let stdinText = try String(contentsOf: dir.appendingPathComponent("stdin"), encoding: .utf8)
        #expect(stdinText == userPrompt)
        // Without it the CLI spends ~1 s on background requests before answering.
        let traffic = try String(contentsOf: dir.appendingPathComponent("traffic"), encoding: .utf8)
        #expect(traffic == "1")
    }
}
