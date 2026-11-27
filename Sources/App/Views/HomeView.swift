import SwiftUI

struct HomeView: View {
    @ObservedObject var coordinator: AppCoordinator
    @FocusState private var isIPFieldFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    headerBar
                    localIPCard
                    connectRemoteCard
                    securityAndPermissionsCard
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .background(LANTheme.background.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Terminer") {
                        isIPFieldFocused = false
                    }
                    .foregroundColor(LANTheme.accentBlue)
                }
            }
        }
        .sheet(item: $coordinator.pendingIncomingRequest) { request in
            IncomingRequestSheet(
                request: request,
                onAccept: { coordinator.acceptIncomingRequest() },
                onDecline: { coordinator.declineIncomingRequest() }
            )
            .interactiveDismissDisabled(true)
            .presentationDetents([.medium])
            .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: $coordinator.isShowingBroadcasterSetup) {
            if let session = coordinator.activeBroadcasterSession {
                BroadcasterReadyView(
                    session: session,
                    runtimeStatus: coordinator.broadcastRuntimeStatus,
                    onStopOrCancel: { coordinator.cancelOrStopBroadcasterSession() }
                )
                .interactiveDismissDisabled(true)
            }
        }
        .fullScreenCover(isPresented: $coordinator.isShowingViewer) {
            RemoteScreenViewerView(coordinator: coordinator)
        }
    }

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.inset.filled.and.person.filled")
                        .font(.title3.weight(.semibold))
                        .foregroundColor(LANTheme.accentBlue)
                    Text("LAN SCREEN")
                        .font(.title2.weight(.heavy))
                        .tracking(1.1)
                        .foregroundColor(LANTheme.textPrimary)
                }

                Text("Miroir iPhone en direct • Wi-Fi local")
                    .font(.caption)
                    .foregroundColor(LANTheme.textSecondary)
            }

            Spacer()

            StatusIndicatorBadge(status: coordinator.connectionStatus)
        }
        .padding(.top, 4)
    }

    private var localIPCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("MON IPHONE (IP LOCALE)", systemImage: "wifi")
                    .font(.caption.weight(.bold))
                    .tracking(0.7)
                    .foregroundColor(LANTheme.textSecondary)

                Spacer()

                Button {
                    coordinator.refreshLocalIP()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(LANTheme.textSecondary)
                        .padding(6)
                        .background(LANTheme.elevatedSurface)
                        .clipShape(Circle())
                }
                .accessibilityLabel("Actualiser l'adresse IP locale")
            }

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(coordinator.localIPAddress ?? "Wi-Fi indisponible")
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .foregroundColor(coordinator.localIPAddress != nil ? LANTheme.textPrimary : LANTheme.disconnectedRed)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)

                    Text(coordinator.isWiFiConnected
                         ? "Partagez cette IP avec l'autre iPhone sur le même Wi-Fi"
                         : "Activez le Wi-Fi pour détecter l'adresse IP locale")
                        .font(.caption)
                        .foregroundColor(LANTheme.textMuted)
                }

                Spacer()

                Button {
                    coordinator.copyLocalIP()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: coordinator.isCopiedBannerVisible ? "checkmark" : "doc.on.doc")
                        Text(coordinator.isCopiedBannerVisible ? "COPIÉ" : "COPIER")
                    }
                    .font(.caption.weight(.bold))
                    .tracking(0.5)
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(coordinator.isCopiedBannerVisible ? LANTheme.connectedGreen : LANTheme.accentBlue)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(coordinator.localIPAddress == nil)
                .opacity(coordinator.localIPAddress == nil ? 0.45 : 1.0)
            }
        }
        .darkCard()
    }

    private var connectRemoteCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("VISUALISER UN AUTRE IPHONE", systemImage: "iphone.radiowaves.left.and.right")
                .font(.caption.weight(.bold))
                .tracking(0.7)
                .foregroundColor(LANTheme.textSecondary)

            HStack(spacing: 10) {
                Image(systemName: "network")
                    .foregroundColor(LANTheme.textMuted)

                TextField("Adresse IP (ex : 192.168.1.37)", text: $coordinator.targetIPInput)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(LANTheme.textPrimary)
                    .focused($isIPFieldFocused)
                    .submitLabel(.go)
                    .onSubmit {
                        isIPFieldFocused = false
                        coordinator.connectToRemoteIP()
                    }

                if !coordinator.targetIPInput.isEmpty {
                    Button {
                        coordinator.targetIPInput = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(LANTheme.textMuted)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(LANTheme.elevatedSurface)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isIPFieldFocused ? LANTheme.accentBlue : LANTheme.hairline, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            if !coordinator.recentIPs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(coordinator.recentIPs, id: \.self) { recent in
                            Button {
                                coordinator.selectRecentIP(recent)
                            } label: {
                                Text(recent)
                                    .font(.caption.monospaced())
                                    .foregroundColor(LANTheme.textSecondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(LANTheme.elevatedSurface)
                                    .overlay(
                                        Capsule().stroke(LANTheme.hairline, lineWidth: 1)
                                    )
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
            }

            if let errorMessage = coordinator.validationErrorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(LANTheme.disconnectedRed)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(LANTheme.disconnectedRed)
                }
            }

            connectionActionButton

            statusBanner
        }
        .darkCard()
    }

    @ViewBuilder
    private var connectionActionButton: some View {
        switch coordinator.connectionStatus {
        case .connecting, .awaitingAcceptance, .waitingForBroadcast:
            Button {
                isIPFieldFocused = false
                coordinator.disconnectViewerSession(notifyPeer: true, reason: "Connexion annulée.")
            } label: {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(.white)
                    Text("ANNULER LA CONNEXION")
                        .font(.subheadline.weight(.bold))
                        .tracking(0.6)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(LANTheme.disconnectedRed.opacity(0.85))
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }

        case .connected:
            Button {
                coordinator.isShowingViewer = true
            } label: {
                Label("AFFICHER EN PLEIN ÉCRAN", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.subheadline.weight(.bold))
                    .tracking(0.6)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(LANTheme.connectedGreen)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }

        default:
            Button {
                isIPFieldFocused = false
                coordinator.connectToRemoteIP()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.horizontal.fill")
                    Text("CONNECTER")
                        .tracking(0.8)
                }
                .font(.subheadline.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(coordinator.isWiFiConnected ? LANTheme.accentBlue : LANTheme.elevatedSurface)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
            .disabled(!coordinator.isWiFiConnected)
        }
    }

    private var statusBanner: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusBannerColor)
                .frame(width: 8, height: 8)

            Text(coordinator.connectionStatus.detailDescription)
                .font(.caption)
                .foregroundColor(LANTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(LANTheme.elevatedSurface.opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var statusBannerColor: Color {
        switch coordinator.connectionStatus {
        case .connected, .broadcasting:
            return LANTheme.connectedGreen
        case .connecting, .awaitingAcceptance, .waitingForBroadcast:
            return LANTheme.pendingAmber
        case .error:
            return LANTheme.disconnectedRed
        case .listening, .disconnected:
            return LANTheme.textMuted
        }
    }

    private var securityAndPermissionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("SÉCURITÉ & AUTORISATIONS IOS", systemImage: "lock.shield.fill")
                .font(.caption.weight(.bold))
                .tracking(0.7)
                .foregroundColor(LANTheme.textSecondary)

            permissionRow(
                icon: "lock.fill",
                title: "Chiffrement bout-en-bout LAN",
                subtitle: "Signalisation TLS 1.2 PSK + Curve25519 ECDH • Flux WebRTC DTLS-SRTP",
                isOK: true
            )

            Divider().overlay(LANTheme.hairline)

            permissionRow(
                icon: "bell.badge.fill",
                title: "Notifications de connexion",
                subtitle: coordinator.permissionsManager.notificationAuthorizationStatus == .denied
                    ? "Refusées dans Réglages — activez-les pour recevoir les demandes en arrière-plan"
                    : "Active les boutons ACCEPTER / REFUSER même en arrière-plan",
                isOK: coordinator.permissionsManager.notificationAuthorizationStatus == .authorized
                    || coordinator.permissionsManager.notificationAuthorizationStatus == .provisional,
                actionTitle: coordinator.permissionsManager.notificationAuthorizationStatus == .denied ? "Réglages" : nil,
                action: { coordinator.permissionsManager.openAppSettings() }
            )

            Divider().overlay(LANTheme.hairline)

            permissionRow(
                icon: "record.circle",
                title: "Confidentialité ReplayKit",
                subtitle: "Aucune capture silencieuse : l'iPhone émetteur doit toujours accepter et confirmer le partage système.",
                isOK: true
            )
        }
        .darkCard()
    }

    private func permissionRow(
        icon: String,
        title: String,
        subtitle: String,
        isOK: Bool,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundColor(isOK ? LANTheme.connectedGreen : LANTheme.pendingAmber)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(LANTheme.textPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(LANTheme.textMuted)
            }

            Spacer()

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.caption.weight(.bold))
                    .foregroundColor(LANTheme.accentBlue)
            }
        }
    }
}
