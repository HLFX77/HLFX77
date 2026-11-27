import Foundation

/// Shared constants across the main app, broadcast upload extension, and unit tests.
public enum AppConstants {
    public static let appName = "LAN SCREEN"
    public static let mainBundleID = "com.lanscreen.app"
    public static let broadcastExtensionBundleID = "com.lanscreen.app.broadcast"
    public static let appGroupID = "group.com.lanscreen.app"

    public static let signalingPort: UInt16 = 54321
    public static let bonjourServiceType = "_lanscreen._tcp"
    public static let protocolVersion = 1

    public static let darwinBroadcastStateNotification = "com.lanscreen.app.broadcastStateChanged"
    public static let darwinStopBroadcastCommandNotification = "com.lanscreen.app.stopBroadcastCommand"

    public static let maxVideoLongEdge: Int = 1280
    public static let targetFPS: Int = 20
    public static let maxVideoBitrateBps: Int = 4_000_000

    public static let sessionExpirySeconds: TimeInterval = 300
    public static let heartbeatIntervalSeconds: TimeInterval = 2.0
    public static let heartbeatTimeoutSeconds: TimeInterval = 7.0
    public static let maxSignalingFrameBytes: Int = 1_048_576 // 1 MB
}
