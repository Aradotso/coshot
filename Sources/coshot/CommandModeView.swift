import SwiftUI

/// The always-visible home-row key row. Typing a letter fires the matching
/// prompt and auto-pastes on completion. Clicking a key opens the inline
/// system-prompt editor for that prompt.
struct HomeRowKeys: View {
    let prompts: [Prompt]
    let lastKey: String
    /// Called with the prompt's index when the user clicks the key with the mouse.
    let onTap: (Int) -> Void

    var body: some View {
        HStack(spacing: 14) {
            ForEach(Array(prompts.enumerated()), id: \.offset) { idx, prompt in
                BigKey(
                    letter: prompt.key.uppercased(),
                    name: prompt.name,
                    active: lastKey.lowercased() == prompt.key.lowercased(),
                    onTap: { onTap(idx) }
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
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
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
            .scaleEffect(active ? 0.94 : (hovering ? 1.015 : 1))
            .animation(.spring(response: 0.22, dampingFraction: 0.65), value: active)
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Click to edit system prompt")
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
