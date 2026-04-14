import SwiftUI

/// The home-row key row. Single-click a tile → run the prompt end-to-end
/// (capture → LLM → clipboard → paste into the frontmost app). Double-click
/// → open the inline system-prompt editor for that prompt.
struct HomeRowKeys: View {
    let prompts: [Prompt]
    let lastKey: String
    let onRun: (Int) -> Void
    let onEdit: (Int) -> Void

    var body: some View {
        HStack(spacing: 14) {
            ForEach(Array(prompts.enumerated()), id: \.offset) { idx, prompt in
                BigKey(
                    letter: prompt.key.uppercased(),
                    name: prompt.name,
                    active: lastKey.lowercased() == prompt.key.lowercased(),
                    onRun:  { onRun(idx) },
                    onEdit: { onEdit(idx) }
                )
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct BigKey: View {
    let letter: String
    let name: String
    let active: Bool
    let onRun: () -> Void
    let onEdit: () -> Void

    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        VStack(spacing: 10) {
            Text(letter)
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(.white.opacity(0.72))
                .padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity, minHeight: 108)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(fillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(borderColor, lineWidth: active ? 2 : 1)
        )
        .scaleEffect(pressed ? 0.94 : (active ? 0.96 : (hovering ? 1.015 : 1)))
        .animation(.spring(response: 0.22, dampingFraction: 0.65), value: active)
        .animation(.easeOut(duration: 0.1), value: pressed)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contentShape(Rectangle())
        // Order matters: double-tap must be evaluated before single-tap so
        // SwiftUI knows to disambiguate.
        .onTapGesture(count: 2) {
            onEdit()
        }
        .onTapGesture(count: 1) {
            pressed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { pressed = false }
            onRun()
        }
        .onHover { hovering = $0 }
        .help("click to run · double-click to edit")
    }

    private var fillColor: Color {
        if active { return .orange.opacity(0.85) }
        if hovering { return .white.opacity(0.12) }
        return .white.opacity(0.06)
    }

    private var borderColor: Color {
        if active { return .orange }
        if hovering { return .white.opacity(0.22) }
        return .white.opacity(0.12)
    }
}
