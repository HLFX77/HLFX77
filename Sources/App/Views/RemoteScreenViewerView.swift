import SwiftUI
import UIKit

struct RemoteScreenViewerView: View {
    @ObservedObject var coordinator: AppCoordinator

    @State private var isHUDVisible: Bool = true
    @State private var useAspectFill: Bool = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let track = coordinator.remoteVideoTrack {
                RemoteVideoRepresentable(
                    videoTrack: track,
                    contentMode: useAspectFill ? .scaleAspectFill : .scaleAspectFit,
                    onVideoSizeChanged: { newSize in
                        coordinator.updateRemoteVideoSize(newSize)
                    }
                )
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isHUDVisible.toggle()
                    }
                }
            } else {
                VStack(spacing: 14) {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.2)
                    Text("Réception du flux WebRTC en direct...")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(LANTheme.textSecondary)
                }
            }

            if isHUDVisible {
                VStack {
                    topOverlayBar
                    Spacer()
                    bottomOverlayHint
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .transition(.opacity)
            }
        }
        .statusBarHidden(!isHUDVisible)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private var topOverlayBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(coordinator.remoteDeviceName)
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                if coordinator.remoteVideoSize != .zero {
                    Text("\(Int(coordinator.remoteVideoSize.width))×\(Int(coordinator.remoteVideoSize.height)) • WebRTC LAN")
                        .font(.caption2.monospaced())
                        .foregroundColor(LANTheme.textSecondary)
                }
            }

            Spacer()

            StatusIndicatorBadge(status: coordinator.connectionStatus)

            Button {
                useAspectFill.toggle()
            } label: {
                Image(systemName: useAspectFill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(9)
                    .background(Color.black.opacity(0.6))
                    .clipShape(Circle())
            }
            .accessibilityLabel("Changer le mode d'affichage")

            Button {
                coordinator.disconnectViewerSession(notifyPeer: true, reason: "Déconnecté par le spectateur.")
            } label: {
                Text("DÉCONNECTER")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(LANTheme.disconnectedRed)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private var bottomOverlayHint: some View {
        Text("Touchez l'écran pour masquer ou afficher les contrôles")
            .font(.caption2)
            .foregroundColor(.white.opacity(0.75))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.55), in: Capsule())
    }
}
