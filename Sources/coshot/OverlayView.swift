import SwiftUI
import AppKit

struct OverlayView: View {
    @Bindable var state: OverlayState
    let onRunPrompt: (Int) -> Void
    let onEditPrompt: (Int) -> Void
    let onSaveEdit: (Int) -> Void
    let onCancelEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if let idx = state.editingPromptIndex, idx < state.prompts.count {
                PromptEditorView(
                    prompt: $state.prompts[idx],
                    onSave: { onSaveEdit(idx) },
                    onCancel: { onCancelEdit() }
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                ocrPreview
                HomeRowKeys(
                    prompts: state.prompts,
                    lastKey: state.lastKey,
                    onRun:  onRunPrompt,
                    onEdit: onEditPrompt
                )
                if !state.output.isEmpty || state.isStreaming {
                    outputPane
                        .transition(.opacity)
                }
                Spacer(minLength: 4)
                footerHint
            }
        }
        .padding(28)
        .frame(minWidth: 760, minHeight: 520, alignment: .topLeading)
        .background(background)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .animation(.easeOut(duration: 0.18), value: state.editingPromptIndex)
        .animation(.easeOut(duration: 0.15), value: state.isStreaming)
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.black.opacity(0.35))
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 10) {
                Text("coshot")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                if state.isConfigMode {
                    Text("CONFIG")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(.white.opacity(0.25), lineWidth: 1)
                        )
                }
            }
            Spacer()
            Text(state.status)
                .font(.system(size: 12, weight: .regular, design: .default))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    // MARK: - OCR preview

    @ViewBuilder
    private var ocrPreview: some View {
        if let ocr = state.ocrText, !ocr.isEmpty {
            ScrollView {
                Text(ocr)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.42))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 64)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.white.opacity(0.06), lineWidth: 1)
                    )
            )
        }
    }

    // MARK: - Output pane

    private var outputPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                Text(state.output.isEmpty ? "…" : state.output)
                    .font(.system(size: 14))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .frame(maxHeight: 160)
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    // MARK: - Footer hint

    private var footerHint: some View {
        HStack(spacing: 6) {
            Spacer()
            if state.isConfigMode {
                Text("click to run · double-click to edit · Esc to dismiss")
            } else if state.isStreaming {
                Text("streaming… will auto-paste when done")
            } else if !state.output.isEmpty {
                Text("pasting into previous app…")
            } else {
                Text("click a letter to run · double-click to edit · ⌥Space to dismiss")
            }
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.38))
    }
}

// MARK: - Inline prompt editor

struct PromptEditorView: View {
    @Binding var prompt: Prompt
    let onSave: () -> Void
    let onCancel: () -> Void

    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                Text(prompt.key.uppercased())
                    .font(.system(size: 14, weight: .heavy, design: .monospaced))
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(.orange.opacity(0.9))
                    )
                Text(prompt.name)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                Spacer()
                Text("SYSTEM PROMPT")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
            }

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                    )
                TextEditor(text: $prompt.template)
                    .focused($editorFocused)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.92))
                    .scrollContentBackground(.hidden)
                    .padding(14)
            }
            .frame(minHeight: 220)

            HStack(alignment: .center, spacing: 12) {
                TextField("Display name", text: $prompt.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.white.opacity(0.05))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                            )
                    )
                    .frame(maxWidth: 220)

                Spacer()

                Button("Cancel", action: onCancel)
                    .buttonStyle(GhostButtonStyle())
                    .keyboardShortcut(.cancelAction)

                Button("Save", action: onSave)
                    .buttonStyle(OrangeButtonStyle())
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
        .onAppear { editorFocused = true }
    }
}

// MARK: - Button styles

struct OrangeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(configuration.isPressed ? .orange.opacity(0.7) : .orange)
            )
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .foregroundStyle(.white.opacity(0.75))
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(configuration.isPressed ? .white.opacity(0.08) : .white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    )
            )
    }
}
