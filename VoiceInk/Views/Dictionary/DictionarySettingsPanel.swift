import SwiftUI
import SwiftData

struct DictionarySettingsPanel: View {
    @Environment(\.modelContext) private var modelContext
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Text("Dictionary Settings")
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(6)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Color(NSColor.windowBackgroundColor))
            .overlay(
                Divider().opacity(0.5), alignment: .bottom
            )

            // Content
            Form {
                Section {
                    LabeledContent("Quick Add to Dictionary") {
                        ShortcutRecorder(action: .quickAddToDictionary)
                            .controlSize(.small)
                    }
                } header: {
                    Text("Shortcuts")
                }

                Section {
                    LabeledContent("Export Dictionary") {
                        Button("Export…") {
                            ImportExportService.shared.exportDictionary(modelContext: modelContext)
                        }
                    }

                    LabeledContent("Import Dictionary") {
                        Button("Import…") {
                            ImportExportService.shared.importDictionary(modelContext: modelContext)
                        }
                    }
                } header: {
                    Text("Backup")
                } footer: {
                    Text("Export or import your vocabulary words and word replacements.")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }
}
