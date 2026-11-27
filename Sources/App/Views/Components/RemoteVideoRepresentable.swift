import SwiftUI
import UIKit
import WebRTC

/// Hardware-accelerated Metal renderer (`RTCMTLVideoView`) wrapped for full-screen SwiftUI playback.
struct RemoteVideoRepresentable: UIViewRepresentable {
    let videoTrack: RTCVideoTrack
    var contentMode: UIView.ContentMode
    var onVideoSizeChanged: (CGSize) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onVideoSizeChanged: onVideoSizeChanged)
    }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let videoView = RTCMTLVideoView(frame: .zero)
        videoView.backgroundColor = .black
        videoView.videoContentMode = contentMode
        videoView.delegate = context.coordinator

        videoTrack.add(videoView)
        context.coordinator.boundTrack = videoTrack
        context.coordinator.boundView = videoView
        return videoView
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        uiView.videoContentMode = contentMode
        if context.coordinator.boundTrack?.trackId != videoTrack.trackId {
            context.coordinator.boundTrack?.remove(uiView)
            videoTrack.add(uiView)
            context.coordinator.boundTrack = videoTrack
        }
    }

    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.boundTrack?.remove(uiView)
        coordinator.boundTrack = nil
        coordinator.boundView = nil
    }

    final class Coordinator: NSObject, RTCVideoViewDelegate {
        var boundTrack: RTCVideoTrack?
        weak var boundView: RTCMTLVideoView?
        private let onVideoSizeChanged: (CGSize) -> Void

        init(onVideoSizeChanged: @escaping (CGSize) -> Void) {
            self.onVideoSizeChanged = onVideoSizeChanged
        }

        func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
            DispatchQueue.main.async {
                self.onVideoSizeChanged(size)
            }
        }
    }
}
