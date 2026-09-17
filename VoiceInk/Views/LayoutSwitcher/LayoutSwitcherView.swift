import SwiftUI

struct LayoutSwitcherView: View {
    @ObservedObject private var settings = LayoutSwitcherSettings.shared
    @EnvironmentObject private var recordingShortcutManager: RecordingShortcutManager
    @State private var layouts: [(id: String, name: String)] = []

    var body: some View {
        Form {
            Section {
                Toggle("Enable Layout Switcher", isOn: $settings.enabled)
                Toggle("Convert automatically at word boundaries", isOn: $settings.autoConvert)
                    .disabled(!settings.enabled)
                LabeledContent {
                    ShortcutRecorder(action: .convertLayout) {
                        recordingShortcutManager.updateShortcutStatus()
                    }
                    .controlSize(.small)
                } label: {
                    HStack(spacing: 4) {
                        Text("Convert Last Word Layout")
                        InfoTip("Converts the last typed word (or the selection) to the other layout. Press again to undo. A single modifier tap such as Right Option works well.")
                    }
                }
            } footer: {
                Text("Fixes words typed in the wrong keyboard layout: ghbdtn → привет. Needs Accessibility and Input Monitoring.")
            }

            Section("Layout Pair") {
                layoutPicker("First layout", selection: $settings.layout1ID)
                layoutPicker("Second layout", selection: $settings.layout2ID)
            }

            Section {
                StringListEditor(items: $settings.neverWords, prompt: "word")
            } header: {
                Text("Never convert")
            } footer: {
                Text("Nicknames, logins, brands. Undoing an automatic conversion adds the word here.")
            }

            Section {
                StringListEditor(items: $settings.alwaysWords, prompt: "target word")
            } header: {
                Text("Always convert")
            } footer: {
                Text("Add the word you want to get, e.g. привет — not the garbage that produced it.")
            }

            Section {
                StringListEditor(items: $settings.deniedApps, prompt: "bundle id or prefix*", locked: LayoutPolicy.protectedApps)
            } header: {
                Text("Apps without automatic conversion")
            } footer: {
                Text("The manual shortcut still works in these apps. Password managers can't be removed.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            layouts = LayoutPair.enabledLayouts().map { (LayoutPair.sourceID($0), LayoutPair.localizedName($0)) }
        }
    }

    private func layoutPicker(_ title: LocalizedStringKey, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("Automatic").tag("")
            ForEach(layouts, id: \.id) { layout in
                Text(layout.name).tag(layout.id)
            }
        }
    }
}

/// Add/remove editor for a list of strings. `locked` entries have no remove button.
struct StringListEditor: View {
    @Binding var items: [String]
    let prompt: LocalizedStringKey
    var locked: Set<String> = []
    @State private var draft = ""

    var body: some View {
        ForEach(items, id: \.self) { item in
            HStack {
                Text(item)
                Spacer()
                if !locked.contains(item) {
                    Button {
                        items.removeAll { $0 == item }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        HStack {
            TextField(prompt, text: $draft)
                .onSubmit(add)
            Button("Add", action: add)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func add() {
        let value = draft.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !items.contains(value) else { return }
        items.append(value)
        draft = ""
    }
}
