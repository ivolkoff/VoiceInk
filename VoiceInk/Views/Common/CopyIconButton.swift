import SwiftUI

struct CopyIconButton: View {
    let textToCopy: String
    @State private var copied = false
    @State private var resetWork: DispatchWorkItem?

    var body: some View {
        Button(action: copy) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(copied ? .green : .secondary)
                .frame(width: 28, height: 28)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.9))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Copy to clipboard")
    }

    private func copy() {
        let _ = ClipboardManager.copyToClipboard(textToCopy)
        withAnimation { copied = true }
        resetWork?.cancel()
        let work = DispatchWorkItem {
            withAnimation { copied = false }
        }
        resetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}
