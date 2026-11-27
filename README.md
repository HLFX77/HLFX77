# LAN SCREEN — Partage d'écran iPhone à iPhone via Wi-Fi local

Application iOS native complète (**Swift + SwiftUI + ReplayKit Broadcast Upload Extension + WebRTC + Network.framework TLS/ECDH**) permettant d'afficher en temps réel l'écran d'un iPhone sur un autre iPhone connecté au même réseau Wi-Fi, sans serveur cloud externe.

## Architecture technique

```text
iPhone A (Spectateur / Viewer)                 iPhone B (Émetteur / Broadcaster)
──────────────────────────────                 ─────────────────────────────────
HomeView (IP locale auto + IP cible)           LANScreen App (NWListener :54321 TLS-PSK)
  │                                               │
  ├─► TLS-PSK + Curve25519 ECDH ─────────────────►├─► Affiche demande ACCEPTER / REFUSER
  │   (Code de sécurité SAS XXX-XXX)              │   (+ Notification locale si arrière-plan)
  │                                               │
  │                                               ├─► Acceptation -> App Group Shared Store
  │                                               └─► RPSystemBroadcastPickerView (consentement iOS)
  │                                                      │
  │                                                      ▼
  │                                              LANScreenBroadcastExtension (SampleHandler)
  │◄── TLS-PSK + HMAC-SHA256 Auth ───────────────├─► Connexion directe vers port éphémère de A
  │◄── WebRTC (SDP + ICE LAN host-only) ─────────├─► VideoToolbox H.264 + VTPixelTransferSession
  └──► RTCMTLVideoView (Plein écran)              └─► Continue même si l'app B est en arrière-plan
```

### Points clés iOS respectés
1. **Consentement explicite obligatoire** : ReplayKit empêche toute capture silencieuse. L'iPhone cible affiche une demande **ACCEPTER / REFUSER** avec code de vérification, puis présente le sélecteur système Apple (`RPSystemBroadcastPickerView`).
2. **Stabilité sous la limite 50 Mo de l'extension ReplayKit** :
   - Encodage matériel **H.264 uniquement** (`RTCVideoEncoderFactoryH264` / `RTCVideoDecoderFactoryH264`).
   - Redimensionnement matériel CoreVideo/VideoToolbox (`VTPixelTransferSession` + `CVPixelBufferPool` réutilisable, côté long max `1280 px`, dimensions paires).
   - Limitation de fréquence (`20 fps`), `autoreleasepool` par image et abandon immédiat si le pipeline est occupé.
3. **Continuité en arrière-plan** : Comme `SampleHandler` tourne dans le processus système `replayd` et établit la session WebRTC directement vers le spectateur, l'utilisateur sur l'iPhone émetteur peut quitter **LAN SCREEN** pour naviguer dans n'importe quelle application tout en continuant à partager son écran.
4. **Sécurité réseau local** :
   - Transport de signalisation chiffré **TLS 1.2 PSK** (`TLS_PSK_WITH_AES_128_GCM_SHA256`) restreint au Wi-Fi (`requiredInterfaceType = .wifi`).
   - Échange de clés éphémère **Curve25519** + dérivation **HKDF-SHA256** (code visuel SAS à 6 chiffres + preuve HMAC-SHA256 pour authentifier l'extension).
   - Flux média WebRTC chiffré via **DTLS-SRTP**, sans serveur STUN/TURN externe.

---

## Compiler, tester et exporter un `.ipa` signé (sur macOS)

> **Prérequis** : macOS avec **Xcode 15.4+** (ou 16+), un compte **Apple Developer** (gratuit pour test local 7 jours sur vos 2 iPhones via Xcode, ou payant pour export Ad-Hoc/Development `.ipa`), et **deux iPhones physiques** sur le même réseau Wi-Fi (ReplayKit Broadcast Upload Extension ne capture pas le système sur Simulateur iOS).

### 1. Configuration de la signature et de l'App Group
1. Ouvrez `LANScreen.xcodeproj` dans Xcode (ou régénérez-le avec `brew install xcodegen && xcodegen generate`).
2. Dans **Signing & Capabilities** des 3 cibles (`LANScreen`, `LANScreenBroadcastExtension`, `LANScreenShared`) :
   - Sélectionnez votre **Team** Apple Developer.
   - Si vous utilisez un Bundle ID personnalisé (ex. `com.votrecompte.lanscreen`), mettez à jour :
     - `PRODUCT_BUNDLE_IDENTIFIER` de `LANScreen`, `LANScreenBroadcastExtension` (`<main>.broadcast`), `LANScreenShared` (`<main>.shared`)
     - L'**App Group** dans `Sources/App/LANScreen.entitlements`, `Sources/BroadcastExtension/LANScreenBroadcastExtension.entitlements`, et `Sources/Shared/AppConstants.swift`.
3. Laissez Xcode résoudre la dépendance Swift Package Manager `https://github.com/stasel/WebRTC.git` (`>= 158.0.0`).

### 2. Lancer les tests unitaires et générer l'IPA
```bash
# Tests unitaires sur simulateur + compilation
./scripts/build_ipa.sh

# Compilation + archive + export IPA signé
TEAM_ID=VOTRE_TEAM_ID ./scripts/build_ipa.sh
```
Le fichier `.ipa` sera produit dans `build/ipa/`.

### 3. Tester sur deux iPhone physiques
1. Installez **LAN SCREEN** sur les deux iPhones via Xcode ou l'IPA signé.
2. Connectez les deux iPhones au même réseau Wi-Fi (évitez l'isolation client / Wi-Fi invité).
3. Acceptez la permission **Réseau local** et **Notifications** au premier lancement.
4. Sur l'iPhone 1, saisissez l'adresse IP affichée sur l'iPhone 2 et appuyez sur **CONNECTER**.
5. Sur l'iPhone 2, vérifiez le code de sécurité et appuyez sur **ACCEPTER**, puis sur **DÉMARRER LE PARTAGE D'ÉCRAN** et confirmez la feuille système Apple **Lancer la diffusion**.
6. L'écran de l'iPhone 2 s'affiche en temps réel en plein écran sur l'iPhone 1.
