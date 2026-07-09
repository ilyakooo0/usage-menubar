import SwiftUI

/// A circular progress "activity ring" that visualises the credit balance
/// relative to a reference maximum. The arc fills clockwise from 12 o'clock
/// and uses a gradient driven by the balance colour, giving a quick at-a-glance
/// sense of how healthy the balance is.
///
/// When the balance exceeds `referenceMax` the ring simply renders as full
/// (clamped to 1.0) so very large balances still look good rather than
/// wrapping around.
struct BalanceRingView: View {
    let balance: Int?
    let color: Color
    /// The balance value that maps to a full ring. 500 is a sensible default
    /// that keeps low double-digit balances visible on the arc.
    var referenceMax: Int = 500
    /// True while a fetch is in flight — dims the ring slightly.
    var isLoading: Bool = false

    /// Progress in the range 0...1.
    private var progress: Double {
        guard let balance, balance > 0 else { return 0 }
        return min(Double(balance) / Double(referenceMax), 1.0)
    }

    var body: some View {
        ZStack {
            // Track
            Circle()
                .stroke(color.opacity(0.15), lineWidth: ringWidth)

            // Progress arc
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    AngularGradient(
                        colors: [color.opacity(0.6), color],
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(360 * progress)
                    ),
                    style: StrokeStyle(lineWidth: ringWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90)) // start from top
                .shadow(color: color.opacity(0.35), radius: 4, x: 0, y: 2)
                .opacity(isLoading ? 0.45 : 1.0)
        }
        .animation(.easeInOut(duration: 0.6), value: progress)
        .animation(.easeInOut(duration: 0.25), value: isLoading)
    }

    private let ringWidth: CGFloat = 9
}
