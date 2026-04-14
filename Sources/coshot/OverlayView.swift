import SwiftUI
import AppKit

struct OverlayView: View {
    @Bindable var state: OverlayState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ocrPreview
            HomeRowKeys(
                prompts: state.prompts,
                lastKey: state.lastKey,
                onEdit: openPromptsFile
            )
            if !state.output.isEmpty || state.isStreaming {
                Divider().opacity(0.2)
                outputPane
            }
            footerHint
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 440, alignment: .topLeading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.black.opacity(0.8))
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            }
        )
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack {
            Text("⚡ coshot")
                .font(.system(.headline, design: .rounded).weight(.bold))
            Spacer()
            Text(state.status)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    @ViewBuilder
    private var ocrPreview: some View {
        if let ocr = state.ocrText, !ocr.isEmpty {
            ScrollView {
                Text(ocr)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 60)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.05)))
        }
    }

    private var outputPane: some View {
        ScrollView {
            Text(state.output.isEmpty ? "…" : state.output)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 130)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.orange.opacity(0.08)))
    }

    private var footerHint: some View {
        Text(hintText)
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.45))
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var hintText: String {
        if state.isStreaming { return "streaming… will auto-paste on finish" }
        if !state.output.isEmpty { return "pasting into previous app…" }
        return "type A · S · D · F · G to run • click a key to edit prompts • Esc to dismiss"
    }

    private func openPromptsFile() {
        _ = PromptLibrary.load() // ensure file exists on disk
        NSWorkspace.shared.open(PromptLibrary.promptsFileURL)
    }
}
