import SwiftUI

/// Scrolling level meter: newest sample on the right.
struct AudioVisualizerView: View {
    var level: Float
    var isActive: Bool
    var tint: Color = .accentColor
    var barCount = 24

    @State private var history: [Float] = []

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(tint.opacity(isActive ? 0.9 : 0.3))
                    .frame(width: 4, height: height(at: index))
            }
        }
        .frame(height: 36)
        .animation(.easeOut(duration: 0.08), value: history)
        .onChange(of: level) { _, newValue in
            history.append(isActive ? newValue : 0)
            if history.count > barCount { history.removeFirst(history.count - barCount) }
        }
        .onChange(of: isActive) { _, active in
            if !active { history = [] }
        }
        .accessibilityHidden(true)
    }

    private func height(at index: Int) -> CGFloat {
        let offset = barCount - history.count
        guard index >= offset else { return 4 }
        return 4 + CGFloat(history[index - offset]) * 32
    }
}

#Preview {
    AudioVisualizerView(level: 0.6, isActive: true)
        .padding()
}
