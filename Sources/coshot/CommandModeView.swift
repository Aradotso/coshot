import SwiftUI

struct CommandModeView: View {
    let prompts: [Prompt]
    let lastKey: String

    private let rows: [[Character]] = [
        ["q","w","e","r","t","y","u","i","o","p"],
        ["a","s","d","f","g","h","j","k","l"],
        ["z","x","c","v","b","n","m"]
    ]

    private func prompt(for c: Character) -> Prompt? {
        prompts.first { $0.key.lowercased() == String(c) }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(.orange).frame(width: 8, height: 8)
                Text("COMMAND MODE")
                    .font(.system(.caption2, design: .monospaced).bold())
                    .foregroundStyle(.orange)
                Text("press a highlighted key")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                Text("ESC to cancel")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
            }

            VStack(spacing: 5) {
                ForEach(0..<rows.count, id: \.self) { i in
                    HStack(spacing: 5) {
                        if i == 1 { Spacer().frame(width: 22) }
                        if i == 2 { Spacer().frame(width: 44) }
                        ForEach(rows[i], id: \.self) { c in
                            KeyCap(
                                letter: c,
                                label: prompt(for: c)?.name,
                                active: lastKey == String(c)
                            )
                        }
                        if i == 1 { Spacer().frame(width: 22) }
                        if i == 2 { Spacer().frame(width: 44) }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

struct KeyCap: View {
    let letter: Character
    let label: String?
    let active: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text(String(letter).uppercased())
                .font(.system(size: 13, weight: .bold, design: .monospaced))
            Text(label ?? " ")
                .font(.system(size: 8))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .opacity(label == nil ? 0 : 1)
        }
        .frame(width: 54, height: 48)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(fillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(label != nil ? .orange.opacity(0.5) : .white.opacity(0.1))
        )
        .foregroundStyle(label != nil ? .white : .white.opacity(0.3))
        .scaleEffect(active ? 0.94 : 1)
        .animation(.easeOut(duration: 0.08), value: active)
    }

    private var fillColor: Color {
        if active { return .orange.opacity(0.8) }
        if label != nil { return .orange.opacity(0.22) }
        return .white.opacity(0.04)
    }
}
