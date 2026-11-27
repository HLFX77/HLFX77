import SwiftUI

enum LANTheme {
    static let background = Color(red: 0.03, green: 0.04, blue: 0.06)
    static let surface = Color(red: 0.07, green: 0.09, blue: 0.13)
    static let elevatedSurface = Color(red: 0.10, green: 0.13, blue: 0.19)
    static let hairline = Color.white.opacity(0.09)

    static let textPrimary = Color.white
    static let textSecondary = Color(red: 0.63, green: 0.68, blue: 0.76)
    static let textMuted = Color(red: 0.43, green: 0.48, blue: 0.56)

    static let accentBlue = Color(red: 0.23, green: 0.53, blue: 0.99)
    static let connectedGreen = Color(red: 0.09, green: 0.78, blue: 0.52)
    static let pendingAmber = Color(red: 0.96, green: 0.65, blue: 0.14)
    static let disconnectedRed = Color(red: 0.94, green: 0.27, blue: 0.27)
}

struct StatusIndicatorBadge: View {
    let status: ConnectionStatus

    private var badgeColor: Color {
        switch status {
        case .connected, .broadcasting:
            return LANTheme.connectedGreen
        case .connecting, .awaitingAcceptance, .waitingForBroadcast:
            return LANTheme.pendingAmber
        case .listening, .disconnected, .error:
            return LANTheme.disconnectedRed
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(badgeColor)
                .frame(width: 8, height: 8)
                .shadow(color: badgeColor.opacity(0.8), radius: 4)

            Text(status.badgeTitle)
                .font(.caption.weight(.bold))
                .tracking(0.8)
                .foregroundColor(badgeColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(badgeColor.opacity(0.14))
        .overlay(
            Capsule()
                .stroke(badgeColor.opacity(0.35), lineWidth: 1)
        )
        .clipShape(Capsule())
    }
}

struct DarkCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(18)
            .background(LANTheme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(LANTheme.hairline, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

extension View {
    func darkCard() -> some View {
        modifier(DarkCardModifier())
    }
}
