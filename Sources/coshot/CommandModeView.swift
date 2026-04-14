import SwiftUI

/// The always-visible home-row key row. Click a key to edit prompts.json;
/// typing a letter fires the matching prompt and auto-pastes on completion.
struct HomeRowKeys: View {
    let prompts: [Prompt]
    let lastKey: String
    let onEdit: () -> Void

    private let letters: [Character] = ["a", "s", "d", "f", "g"]

    private func prompt(for c: Character) -> Prompt? {
        prompts.first { $0.key.lowercased() == String(c) }
    }

    var body: some View {
        HStack(spacing: 12) {
            ForEach(letters, id: \.self) { c in
                BigKey(
                    letter: c,
                    name: prompt(for: c)?.name ?? "—",
                    enabled: prompt(for: c) != nil,
                    active: lastKey == String(c),
                    onTap: onEdit
                )
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct BigKey: View {
    let letter: Character
    let name: String
    let enabled: Bool
    let active: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                Text(String(letter).uppercased())
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                Text(name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 4)
            }
            .frame(maxWidth: .infinity, minHeight: 96)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(fillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: active ? 2 : 1)
            )
            .scaleEffect(active ? 0.94 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: active)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.white : Color.white.opacity(0.3))
        .help("Click to edit prompts.json")
    }

    private var fillColor: Color {
        if active { return .orange.opacity(0.85) }
        if enabled { return .orange.opacity(0.22) }
        return .white.opacity(0.05)
    }

    private var borderColor: Color {
        if active { return .orange }
        if enabled { return .orange.opacity(0.55) }
        return .white.opacity(0.1)
    }
}
