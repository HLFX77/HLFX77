import LANScreenShared
import ReplayKit
import SwiftUI

struct BroadcasterReadyView: View {
    let session: BroadcasterSessionSummary
    let runtimeStatus: BroadcastRuntimeStatus
    let onStopOrCancel: () -> Void

    @State private var broadcastPicker: RPSystemBroadcastPickerView?

    private var isLive: Bool {
        runtimeStatus.phase == .broadcasting
    }

    var body: some View {
        VStack(spacing: 22) {
            HStack {
                StatusIndicatorBadge(status: isLive ? .broadcasting : .waitingForBroadcast(code: session.verificationCode))
                Spacer()
                Text("Code : \(session.verificationCode)")
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundColor(LANTheme.textSecondary)
            }

            Spacer()

            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill((isLive ? LANTheme.connectedGreen : LANTheme.accentBlue).opacity(0.16))
                        .frame(width: 84, height: 84)
                    Image(systemName: isLive ? "dot.radiowaves.left.and.right" : "record.circle")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundColor(isLive ? LANTheme.connectedGreen : LANTheme.accentBlue)
                }

                Text(isLive ? "Partage d'écran en direct" : "Connexion acceptée")
                    .font(.title2.weight(.bold))
                    .foregroundColor(LANTheme.textPrimary)

                Text("Spectateur autorisé : \(session.viewerName) (\(session.viewerIP))")
                    .font(.subheadline)
                    .foregroundColor(LANTheme.textSecondary)
                    .multilineTextAlignment(.center)

                Text(runtimeStatus.message ?? "Appuyez ci-dessous pour autoriser iOS à démarrer la diffusion ReplayKit.")
                    .font(.caption)
                    .foregroundColor(LANTheme.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }

            ZStack {
                SystemBroadcastPickerRepresentable { picker in
                    self.broadcastPicker = picker
                }
                .frame(width: 60, height: 60)
                .opacity(0.01)
                .allowsHitTesting(false)

                Button {
                    broadcastPicker?.triggerSystemBroadcastSheet()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: isLive ? "stop.circle.fill" : "play.circle.fill")
                            .font(.title3)
                        Text(isLive ? "CONTRÔLER LA DIFFUSION" : "DÉMARRER LE PARTAGE D'ÉCRAN")
                            .font(.subheadline.weight(.bold))
                            .tracking(0.6)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(isLive ? LANTheme.elevatedSurface : LANTheme.accentBlue)
                    .overlay(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .stroke(isLive ? LANTheme.connectedGreen.opacity(0.6) : Color.clear, lineWidth: 1)
                    )
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
            }

            if isLive {
                Text("Vous pouvez maintenant quitter LAN SCREEN : la diffusion continue sur tout le système jusqu'à l'arrêt.")
                    .font(.caption)
                    .foregroundColor(LANTheme.connectedGreen)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }

            Spacer()

            Button(role: .destructive, action: onStopOrCancel) {
                Text(isLive ? "ARRÊTER LE PARTAGE" : "ANNULER")
                    .font(.subheadline.weight(.bold))
                    .tracking(0.6)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(LANTheme.disconnectedRed.opacity(0.18))
                    .foregroundColor(LANTheme.disconnectedRed)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
        }
        .padding(22)
        .background(LANTheme.background.ignoresSafeArea())
    }
}
