import SwiftUI

struct HomeRowKeys: View {
    let prompts: [Prompt]
    let lastKey: String
    let onRun: (Int) -> Void
    let onEdit: (Int) -> Void

    var body: some View {
        HStack(spacing: 10) {
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(letter)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Rectangle()
                    .fill(.white.opacity(active ? 0.9 : 0.18))
                    .frame(width: 4, height: 4)
                    .padding(.top, 10)
            }
            Spacer(minLength: 0)
            Text(name.lowercased())
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(.white.opacity(0.65))
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: OverlayView.r, style: .continuous)
                .fill(fillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: OverlayView.r, style: .continuous)
                .strokeBorder(borderColor, lineWidth: active ? 1.5 : 1)
        )
        .scaleEffect(pressed ? 0.97 : 1)
        .animation(.easeOut(duration: 0.1), value: pressed)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.18), value: active)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onEdit() }
        .onTapGesture(count: 1) {
            pressed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { pressed = false }
            onRun()
        }
        .onHover { hovering = $0 }
        .help("click to run · double-click to edit")
    }

    private var fillColor: Color {
        if active { return Color(white: 0.18) }
        if hovering { return Color(white: 0.11) }
        return Color(white: 0.085)
    }

    private var borderColor: Color {
        if active { return .white.opacity(0.7) }
        if hovering { return .white.opacity(0.22) }
        return .white.opacity(0.1)
    }
}
