import Foundation
import Testing
@testable import VoiceInk

struct LocalCLITemplateTests {
    @Test func migratesBuiltInClaudeCommandsAndKeepsCustomCommands() throws {
        let suiteName = "VoiceInkTests.LocalCLI.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let legacyCommand = "claude --model sonnet --strict-mcp-config --setting-sources \"\" -p \"$VOICEINK_FULL_PROMPT\""
        let previousCommand = """
            printf '%s' "$VOICEINK_USER_PROMPT" | CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 claude -p \\
              --model claude-sonnet-5-5 \\
              --effort low \\
              --system-prompt "$VOICEINK_SYSTEM_PROMPT" \\
              --tools="" \\
              --max-turns 1 \\
              --strict-mcp-config \\
              --setting-sources "" \\
              --disable-slash-commands \\
              --no-session-persistence \\
              --fallback-model claude-haiku-5-5
            """

        for command in [legacyCommand, previousCommand] {
            defaults.set(command, forKey: LocalCLIService.commandTemplateKey)
            #expect(LocalCLIService(defaults: defaults).commandTemplate == LocalCLITemplate.claude.commandTemplate)
        }

        let customCommand = previousCommand.replacingOccurrences(of: "--effort low", with: "--effort high")
        defaults.set(customCommand, forKey: LocalCLIService.commandTemplateKey)
        #expect(LocalCLIService(defaults: defaults).commandTemplate == customCommand)
    }

    @Test func failedCommandReportsStdoutBeforeStderr() async throws {
        let suiteName = "VoiceInkTests.LocalCLI.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("""
            printf '%s\\n' 'Claude cannot use your subscription'
            printf '%s\\n' 'Warning: sign-in expires soon' >&2
            exit 1
            """, forKey: LocalCLIService.commandTemplateKey)

        let service = LocalCLIService(defaults: defaults)
        do {
            _ = try await service.enhance(systemPrompt: "Improve text", userPrompt: "Sample text")
            Issue.record("Expected the failing command to produce an error")
        } catch LocalCLIError.nonZeroExit(let status, let details) {
            #expect(status == 1)
            #expect(details == "Claude cannot use your subscription\nWarning: sign-in expires soon")
        }
    }

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
        #expect(args.contains("--safe-mode"))
        #expect(value(after: "--setting-sources") == "user")
        let stdinText = try String(contentsOf: dir.appendingPathComponent("stdin"), encoding: .utf8)
        #expect(stdinText == userPrompt)
        // Without it the CLI spends ~1 s on background requests before answering.
        let traffic = try String(contentsOf: dir.appendingPathComponent("traffic"), encoding: .utf8)
        #expect(traffic == "1")
    }
}
