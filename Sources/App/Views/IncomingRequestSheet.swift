import SwiftUI

struct IncomingRequestSheet: View {
    let request: IncomingConnectionRequest
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(LANTheme.accentBlue.opacity(0.18))
                        .frame(width: 64, height: 64)
                    Image(systemName: "display.and.arrow.down")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(LANTheme.accentBlue)
                }

                Text("Demande de connexion")
                    .font(.title3.weight(.bold))
                    .foregroundColor(LANTheme.textPrimary)

                Text("\(request.viewerName) (\(request.viewerIP)) souhaite voir l'écran de cet iPhone en direct.")
                    .font(.subheadline)
                    .foregroundColor(LANTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }

            VStack(spacing: 6) {
                Text("CODE DE VÉRIFICATION")
                    .font(.caption2.weight(.bold))
                    .tracking(0.9)
                    .foregroundColor(LANTheme.textMuted)
                Text(request.verificationCode)
                    .font(.system(size: 26, weight: .heavy, design: .monospaced))
                    .foregroundColor(LANTheme.connectedGreen)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(LANTheme.elevatedSurface)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(LANTheme.hairline, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(spacing: 12) {
                Button(action: onDecline) {
                    Text("REFUSER")
                        .font(.subheadline.weight(.bold))
                        .tracking(0.6)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(LANTheme.disconnectedRed.opacity(0.2))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(LANTheme.disconnectedRed.opacity(0.6), lineWidth: 1)
                        )
                        .foregroundColor(LANTheme.disconnectedRed)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                Button(action: onAccept) {
                    Text("ACCEPTER")
                        .font(.subheadline.weight(.bold))
                        .tracking(0.6)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(LANTheme.connectedGreen)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LANTheme.background.ignoresSafeArea())
    }
}
