import SwiftUI
import AppKit

struct OverlayView: View {
    @Bindable var state: OverlayState
    let onRunPrompt: (Int) -> Void
    let onEditPrompt: (Int) -> Void
    let onSaveEdit: (Int) -> Void
    let onCancelEdit: () -> Void
    let onFixScreenRecording: () -> Void
    let onFixAccessibility: () -> Void
    let onFixApiKey: () -> Void

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
                if state.isConfigMode {
                    PermissionsPanel(
                        hasScreenRecording: state.hasScreenRecording,
                        hasAccessibility: state.hasAccessibility,
                        hasApiKey: state.hasApiKey,
                        onFixScreenRecording: onFixScreenRecording,
                        onFixAccessibility: onFixAccessibility,
                        onFixApiKey: onFixApiKey
                    )
                    .transition(.opacity)
                }
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

// MARK: - Permissions panel (config mode)

struct PermissionsPanel: View {
    let hasScreenRecording: Bool
    let hasAccessibility: Bool
    let hasApiKey: Bool
    let onFixScreenRecording: () -> Void
    let onFixAccessibility: () -> Void
    let onFixApiKey: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PERMISSIONS")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.42))

            VStack(spacing: 6) {
                PermissionRow(
                    name: "Screen Recording",
                    subtitle: "needed to capture your screen for OCR",
                    granted: hasScreenRecording,
                    onFix: onFixScreenRecording
                )
                PermissionRow(
                    name: "Accessibility",
                    subtitle: "needed for ⌥Space listen mode and auto-paste",
                    granted: hasAccessibility,
                    onFix: onFixAccessibility
                )
                PermissionRow(
                    name: "Cerebras API Key",
                    subtitle: "needed to stream responses from Cerebras",
                    granted: hasApiKey,
                    onFix: onFixApiKey
                )
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                )
        )
        .animation(.easeOut(duration: 0.2), value: hasScreenRecording)
        .animation(.easeOut(duration: 0.2), value: hasAccessibility)
        .animation(.easeOut(duration: 0.2), value: hasApiKey)
    }
}

struct PermissionRow: View {
    let name: String
    let subtitle: String
    let granted: Bool
    let onFix: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(granted ? Color.green : Color.red.opacity(0.85))
                    .frame(width: 10, height: 10)
                Circle()
                    .stroke(.black.opacity(0.35), lineWidth: 0.5)
                    .frame(width: 10, height: 10)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.42))
            }

            Spacer()

            if granted {
                Text("granted")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.green.opacity(0.85))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(.green.opacity(0.12))
                    )
            } else {
                Button(action: onFix) {
                    Text("Grant")
                }
                .buttonStyle(OrangeButtonStyle())
            }
        }
    }
}

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
