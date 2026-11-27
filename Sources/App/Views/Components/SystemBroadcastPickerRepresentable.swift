import LANScreenShared
import ReplayKit
import SwiftUI
import UIKit

/// Wraps Apple's `RPSystemBroadcastPickerView` so a modern SwiftUI button can invoke the system screen-share prompt.
struct SystemBroadcastPickerRepresentable: UIViewRepresentable {
    var onPickerReady: (RPSystemBroadcastPickerView) -> Void

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        picker.preferredExtension = AppConstants.broadcastExtensionBundleID
        picker.showsMicrophoneButton = false
        DispatchQueue.main.async {
            onPickerReady(picker)
        }
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        uiView.preferredExtension = AppConstants.broadcastExtensionBundleID
    }
}

extension RPSystemBroadcastPickerView {
    /// Triggers the internal system `UIButton` so iOS presents the mandatory ReplayKit broadcast confirmation sheet.
    func triggerSystemBroadcastSheet() {
        for subview in subviews {
            if let button = subview as? UIButton {
                button.sendActions(for: .touchUpInside)
                return
            }
        }
    }
}
