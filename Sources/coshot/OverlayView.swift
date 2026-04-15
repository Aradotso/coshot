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

    // Ara design tokens
    static let r: CGFloat = 4          // corner radius (Ara uses 3px, we round to 4)
    static let rLarge: CGFloat = 6     // outer container radius
    static let pagePad: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if state.isConfigMode {
                banner
            }

            VStack(alignment: .leading, spacing: 18) {
                header

                if let idx = state.editingPromptIndex, idx < state.prompts.count {
                    PromptEditorView(
                        prompt: $state.prompts[idx],
                        reservedKeys: Set(
                            state.prompts.enumerated().compactMap { offset, prompt in
                                offset == idx ? nil : prompt.key.lowercased()
                            }
                        ),
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
            .padding(Self.pagePad)
        }
        .frame(minWidth: 780, minHeight: state.isConfigMode ? 620 : 480, alignment: .topLeading)
        .background(background)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .font(.system(.body, design: .default))
        .animation(.easeOut(duration: 0.18), value: state.editingPromptIndex)
        .animation(.easeOut(duration: 0.15), value: state.isStreaming)
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Self.rLarge, style: .continuous)
                .fill(Color(white: 0.07))
            RoundedRectangle(cornerRadius: Self.rLarge, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        }
    }

    // MARK: - Ara banner (config mode only)

    @ViewBuilder
    private var banner: some View {
        if let url = AppResources.url(forResource: "AraArt", withExtension: "png"),
           let nsImage = NSImage(contentsOf: url) {
            ZStack(alignment: .bottomLeading) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 132)
                    .frame(maxWidth: .infinity)
                    .clipped()

                LinearGradient(
                    colors: [.black.opacity(0.0), .black.opacity(0.55)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 132)
            }
            .frame(height: 132)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: Self.rLarge,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: Self.rLarge,
                    style: .continuous
                )
            )
            .overlay(alignment: .bottomLeading) {
                HStack {
                    Rectangle()
                        .fill(.white)
                        .frame(width: 2, height: 28)
                    Text("coshot")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("/ ara")
                        .font(.system(size: 14, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .padding(.leading, Self.pagePad)
                .padding(.bottom, 16)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            if !state.isConfigMode {
                Text("coshot")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
            }
            Spacer()
            Text(state.status)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .textCase(.lowercase)
        }
    }

    // MARK: - OCR preview

    @ViewBuilder
    private var ocrPreview: some View {
        if let ocr = state.ocrText, !ocr.isEmpty {
            ScrollView {
                Text(ocr)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 56)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: Self.r)
                    .fill(.white.opacity(0.035))
                    .overlay(
                        RoundedRectangle(cornerRadius: Self.r)
                            .strokeBorder(.white.opacity(0.07), lineWidth: 1)
                    )
            )
        }
    }

    // MARK: - Output pane

    private var outputPane: some View {
        ScrollView {
            Text(state.output.isEmpty ? "…" : state.output)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .frame(maxHeight: 150)
        .background(
            RoundedRectangle(cornerRadius: Self.r)
                .fill(.white.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: Self.r)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    // MARK: - Footer hint

    private var footerHint: some View {
        HStack(spacing: 6) {
            Spacer()
            if state.isConfigMode {
                Text("click to run · double-click to edit · esc to dismiss")
            } else if state.isStreaming {
                Text("streaming… will auto-paste when done")
            } else if !state.output.isEmpty {
                Text("pasting…")
            } else {
                Text("click a key to run · double-click to edit · ⌥space to dismiss")
            }
            Spacer()
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.white.opacity(0.35))
        .textCase(.lowercase)
    }
}

// MARK: - Inline prompt editor

struct PromptEditorView: View {
    @Binding var prompt: Prompt
    let reservedKeys: Set<String>
    let onSave: () -> Void
    let onCancel: () -> Void

    @FocusState private var editorFocused: Bool
    private let keyGridColumns = Array(repeating: GridItem(.fixed(30), spacing: 6), count: 12)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                Text(prompt.key.uppercased())
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: OverlayView.r)
                            .fill(.white)
                    )
                    .foregroundStyle(.black)
                Text(prompt.name)
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Text("SYSTEM PROMPT")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
            }

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: OverlayView.r)
                    .fill(.white.opacity(0.045))
                    .overlay(
                        RoundedRectangle(cornerRadius: OverlayView.r)
                            .strokeBorder(.white.opacity(0.09), lineWidth: 1)
                    )
                TextEditor(text: $prompt.template)
                    .focused($editorFocused)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.92))
                    .scrollContentBackground(.hidden)
                    .padding(14)
            }
            .frame(minHeight: 200)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("SHORTCUT KEY")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                    Text("choose one unique key")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                }

                LazyVGrid(columns: keyGridColumns, alignment: .leading, spacing: 6) {
                    ForEach(ListenModeTap.keyPickerOrder, id: \.self) { key in
                        let keyString = String(key)
                        let isSelected = prompt.key.lowercased() == keyString
                        let isReserved = reservedKeys.contains(keyString) && !isSelected

                        Button {
                            prompt.key = keyString
                        } label: {
                            Text(keyString.uppercased())
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .frame(width: 30, height: 24)
                                .foregroundStyle(isSelected ? .black : .white.opacity(isReserved ? 0.35 : 0.9))
                                .background(
                                    RoundedRectangle(cornerRadius: OverlayView.r)
                                        .fill(isSelected ? .white : .white.opacity(isReserved ? 0.05 : 0.12))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: OverlayView.r)
                                        .strokeBorder(isSelected ? .white : .white.opacity(0.14), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(isReserved)
                        .help(isReserved ? "already used by another prompt" : "set shortcut key")
                    }
                }
            }

            HStack(alignment: .center, spacing: 10) {
                TextField("display name", text: $prompt.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: OverlayView.r)
                            .fill(.white.opacity(0.045))
                            .overlay(
                                RoundedRectangle(cornerRadius: OverlayView.r)
                                    .strokeBorder(.white.opacity(0.09), lineWidth: 1)
                            )
                    )
                    .frame(maxWidth: 220)

                Spacer()

                Button("cancel", action: onCancel)
                    .buttonStyle(GhostButtonStyle())
                    .keyboardShortcut(.cancelAction)

                Button("save", action: onSave)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
        .onAppear { editorFocused = true }
    }
}

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
                .foregroundStyle(.white.opacity(0.4))

            VStack(spacing: 6) {
                PermissionRow(
                    name: "screen recording",
                    subtitle: "captures your screen for ocr",
                    granted: hasScreenRecording,
                    onFix: onFixScreenRecording
                )
                PermissionRow(
                    name: "accessibility",
                    subtitle: "⌥space listen mode and auto-paste",
                    granted: hasAccessibility,
                    onFix: onFixAccessibility
                )
                PermissionRow(
                    name: "cerebras api key",
                    subtitle: "streams responses from cerebras",
                    granted: hasApiKey,
                    onFix: onFixApiKey
                )
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: OverlayView.r)
                .fill(.white.opacity(0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: OverlayView.r)
                        .strokeBorder(.white.opacity(0.07), lineWidth: 1)
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
            Rectangle()
                .fill(granted ? Color.green : Color.red.opacity(0.85))
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .textCase(.lowercase)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.42))
                    .textCase(.lowercase)
            }

            Spacer()

            if granted {
                Text("granted")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: OverlayView.r)
                            .stroke(.green.opacity(0.4), lineWidth: 1)
                    )
            } else {
                Button(action: onFix) {
                    Text("grant")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
    }
}

// MARK: - Button styles

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(.black)
            .background(
                RoundedRectangle(cornerRadius: OverlayView.r)
                    .fill(configuration.isPressed ? Color.white.opacity(0.75) : .white)
            )
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(.white.opacity(0.75))
            .background(
                RoundedRectangle(cornerRadius: OverlayView.r)
                    .fill(configuration.isPressed ? .white.opacity(0.08) : .clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: OverlayView.r)
                            .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                    )
            )
    }
}
