import SwiftUI

struct OverlayView: View {
    @Bindable var state: OverlayState
    let onSubmit: (Prompt) -> Void
    let onPaste: () -> Void
    let onEscape: () -> Void

    @State private var library = PromptLibrary.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ocrPreview
            Divider().opacity(0.3)
            middle
            if !state.output.isEmpty {
                Divider().opacity(0.3)
                outputPane
            }
        }
        .padding(18)
        .frame(minWidth: 680, minHeight: 480, alignment: .topLeading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.black.opacity(0.78))
                RoundedRectangle(cornerRadius: 18, style: .continuous)
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
            .frame(maxHeight: 70)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.05)))
        }
    }

    @ViewBuilder
    private var middle: some View {
        if state.commandMode {
            CommandModeView(prompts: library.prompts, lastKey: state.lastKey)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Press SPACE for command mode — or click:")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6)], spacing: 6) {
                    ForEach(library.prompts) { p in
                        Button(action: { onSubmit(p) }) {
                            HStack(spacing: 8) {
                                Text(p.key.uppercased())
                                    .font(.system(.caption, design: .monospaced).bold())
                                    .frame(width: 18, height: 18)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(.orange.opacity(0.4)))
                                Text(p.name)
                                    .font(.caption)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var outputPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView {
                Text(state.output)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06)))

            HStack {
                Spacer()
                Button("Paste ⌘↩") { onPaste() }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            }
        }
    }
}
