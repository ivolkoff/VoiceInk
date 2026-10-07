import SwiftUI

struct MeetingsView: View {
    @EnvironmentObject private var recorder: MeetingRecorder
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager

    var body: some View {
        Form {
            Section("Recording") {
                Picker("App", selection: $recorder.selectedBundleID) {
                    Text("Choose an app").tag(String?.none)
                    ForEach(recorder.apps) { app in
                        Label { Text(app.name) } icon: { Image(nsImage: app.icon) }
                            .tag(Optional(app.id))
                    }
                }
                .disabled(recorder.state != .idle)

                Toggle("Include microphone", isOn: $recorder.includeMicrophone)
                    .disabled(recorder.state != .idle)

                Picker("Language", selection: $recorder.languageChoice) {
                    ForEach(languageOptions, id: \.code) { option in
                        Text(option.name).tag(option.code)
                    }
                }

                HStack(spacing: 10) {
                    recordButton
                    stateLabel
                    Spacer()
                }

                if let status = recorder.status {
                    Text(status).foregroundStyle(.secondary)
                }

                if let error = recorder.error {
                    HStack(alignment: .firstTextBaseline) {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                        Spacer()
                        if recorder.needsScreenPermission {
                            Button("Open Privacy Settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                        Button("Dismiss") { recorder.error = nil }
                    }
                }
            }

            Section("Recordings") {
                if recorder.recordings.isEmpty {
                    Text("No recordings yet. They're saved in ~/Music/Recordings.")
                        .foregroundStyle(.secondary)
                }
                ForEach(recorder.recordings) { recording in
                    MeetingRow(recording: recording)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            recorder.refreshApps()
            recorder.refreshRecordings()
        }
    }

    @ViewBuilder
    private var recordButton: some View {
        if recorder.isRecording {
            Button {
                Task { await recorder.stop() }
            } label: {
                Label("Stop", systemImage: "stop.circle.fill")
            }
        } else {
            Button {
                Task { await recorder.start() }
            } label: {
                Label("Record", systemImage: "record.circle")
            }
            .disabled(recorder.selectedBundleID == nil || recorder.state != .idle)
        }
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch recorder.state {
        case .recording(let startedAt, let appName):
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text("Recording \(appName) · \(MeetingText.timestamp(context.date.timeIntervalSince(startedAt)))")
                    .monospacedDigit()
                    .foregroundStyle(.red)
            }
        case .saving:
            ProgressView().controlSize(.small)
            Text("Saving…").foregroundStyle(.secondary)
        case .idle:
            EmptyView()
        }
    }

    private var languageOptions: [(code: String, name: String)] {
        var languages: [String: String] = [:]
        if let model = transcriptionModelManager.currentTranscriptionModel {
            languages = TranscriptionLanguageSupport.languages(for: model)
        }
        languages[MeetingLanguage.auto] = nil
        var options = languages.map { (code: $0.key, name: $0.value) }.sorted { $0.name < $1.name }
        if recorder.languageChoice != MeetingLanguage.auto, languages[recorder.languageChoice] == nil {
            options.insert((code: recorder.languageChoice, name: recorder.languageChoice), at: 0)
        }
        return [(code: MeetingLanguage.auto, name: String(localized: "Auto-detect"))] + options
    }
}

private struct MeetingRow: View {
    @EnvironmentObject private var recorder: MeetingRecorder
    let recording: MeetingRecording
    @State private var duration: TimeInterval?

    var body: some View {
        let step = recorder.steps[recording.folder]
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.name).lineLimit(1).truncationMode(.middle)
                Text(details).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            switch step {
            case .queued:
                Text("Queued").font(.caption).foregroundStyle(.secondary)
            case .transcribing, .summarizing:
                ProgressView().controlSize(.small)
            case nil:
                EmptyView()
            }
            if recording.hasTranscript {
                iconButton("doc.text", help: "Transcript") { NSWorkspace.shared.open(recording.transcriptURL) }
            } else if step == nil {
                Button("Transcribe") { recorder.enqueueTranscription(recording.folder) }
            }
            if recording.hasSummary {
                iconButton("list.bullet.rectangle", help: "Summary") { NSWorkspace.shared.open(recording.summaryURL) }
            } else if recording.hasTranscript, step == nil, recorder.canSummarize {
                Button("Summarize") { recorder.createSummary(recording) }
            }
            iconButton("play.circle", help: "Play") { NSWorkspace.shared.open(recording.audioURL) }
            iconButton("trash", help: "Move to Trash") { recorder.trash(recording) }
                .disabled(step == .transcribing || step == .summarizing)
        }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([recording.folder]) }
        }
        .task(id: recording.folder) {
            duration = await AudioFileMetadata.duration(for: recording.audioURL)
        }
    }

    private var details: String {
        let date = recording.date.formatted(date: .abbreviated, time: .shortened)
        guard let duration, duration > 0 else { return date }
        return "\(date) · \(MeetingText.timestamp(duration))"
    }

    private func iconButton(_ systemImage: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: systemImage) }
            .buttonStyle(.borderless)
            .help(help)
    }
}
