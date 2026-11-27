import Foundation

/// Accepted pairing configuration written by the Main App and consumed by the ReplayKit Broadcast Extension.
public struct AcceptedBroadcastSession: Codable, Equatable {
    public let sessionId: String
    public let viewerIP: String
    public let viewerExtensionPort: UInt16
    public let sessionAuthTokenBase64: String
    public let viewerName: String
    public let broadcasterName: String
    public let createdAt: TimeInterval
    public let maxLongEdge: Int
    public let targetFPS: Int

    public init(
        sessionId: String,
        viewerIP: String,
        viewerExtensionPort: UInt16,
        sessionAuthTokenBase64: String,
        viewerName: String,
        broadcasterName: String,
        createdAt: TimeInterval = Date().timeIntervalSince1970,
        maxLongEdge: Int = AppConstants.maxVideoLongEdge,
        targetFPS: Int = AppConstants.targetFPS
    ) {
        self.sessionId = sessionId
        self.viewerIP = viewerIP
        self.viewerExtensionPort = viewerExtensionPort
        self.sessionAuthTokenBase64 = sessionAuthTokenBase64
        self.viewerName = viewerName
        self.broadcasterName = broadcasterName
        self.createdAt = createdAt
        self.maxLongEdge = maxLongEdge
        self.targetFPS = targetFPS
    }

    public func isExpired(referenceDate: Date = Date(), maxAge: TimeInterval = AppConstants.sessionExpirySeconds) -> Bool {
        referenceDate.timeIntervalSince1970 - createdAt > maxAge
    }

    public var sessionAuthTokenData: Data? {
        Data(base64Encoded: sessionAuthTokenBase64)
    }
}

/// Live broadcast state reported by the Broadcast Upload Extension back to the Host App.
public struct BroadcastRuntimeStatus: Codable, Equatable {
    public enum Phase: String, Codable, Equatable {
        case idle
        case connecting
        case broadcasting
        case stopped
        case error
    }

    public let sessionId: String?
    public let phase: Phase
    public let message: String?
    public let width: Int
    public let height: Int
    public let updatedAt: TimeInterval

    public init(
        sessionId: String?,
        phase: Phase,
        message: String? = nil,
        width: Int = 0,
        height: Int = 0,
        updatedAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.sessionId = sessionId
        self.phase = phase
        self.message = message
        self.width = width
        self.height = height
        self.updatedAt = updatedAt
    }
}

/// Cross-process App Group store backed by `UserDefaults(suiteName:)`.
public final class AppGroupSessionStore {
    private enum Keys {
        static let pendingSession = "lanscreen.pendingBroadcastSession"
        static let runtimeStatus = "lanscreen.broadcastRuntimeStatus"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(suiteName: String = AppConstants.appGroupID) {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    public init(userDefaults: UserDefaults) {
        self.defaults = userDefaults
    }

    public func savePendingSession(_ session: AcceptedBroadcastSession) {
        if let data = try? encoder.encode(session) {
            defaults.set(data, forKey: Keys.pendingSession)
            defaults.synchronize()
        }
    }

    public func loadPendingSession() -> AcceptedBroadcastSession? {
        guard let data = defaults.data(forKey: Keys.pendingSession) else {
            return nil
        }
        return try? decoder.decode(AcceptedBroadcastSession.self, from: data)
    }

    public func clearPendingSession() {
        defaults.removeObject(forKey: Keys.pendingSession)
        defaults.synchronize()
    }

    public func saveRuntimeStatus(_ status: BroadcastRuntimeStatus) {
        if let data = try? encoder.encode(status) {
            defaults.set(data, forKey: Keys.runtimeStatus)
            defaults.synchronize()
        }
    }

    public func loadRuntimeStatus() -> BroadcastRuntimeStatus? {
        guard let data = defaults.data(forKey: Keys.runtimeStatus) else {
            return nil
        }
        return try? decoder.decode(BroadcastRuntimeStatus.self, from: data)
    }

    public func clearAll() {
        defaults.removeObject(forKey: Keys.pendingSession)
        defaults.removeObject(forKey: Keys.runtimeStatus)
        defaults.synchronize()
    }
}

/// Lightweight Darwin notification helper for IPC events between Main App and Broadcast Extension.
public final class DarwinNotifier {
    public typealias Callback = () -> Void

    private let lock = NSLock()
    private var observations: [String: Callback] = [:]

    public static let shared = DarwinNotifier()

    private init() {}

    public func post(name: String) {
        let cfName = CFNotificationName(name as CFString)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            cfName,
            nil,
            nil,
            true
        )
    }

    public func observe(name: String, callback: @escaping Callback) {
        lock.lock()
        let alreadyRegistered = observations[name] != nil
        observations[name] = callback
        lock.unlock()

        guard !alreadyRegistered else { return }

        let observerPointer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observerPointer,
            { _, observer, cfName, _, _ in
                guard let observer, let cfName else { return }
                let instance = Unmanaged<DarwinNotifier>.fromOpaque(observer).takeUnretainedValue()
                let key = cfName.rawValue as String
                instance.invoke(for: key)
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    public func stopObserving(name: String) {
        lock.lock()
        observations.removeValue(forKey: name)
        lock.unlock()

        let observerPointer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observerPointer,
            CFNotificationName(name as CFString),
            nil
        )
    }

    private func invoke(for name: String) {
        lock.lock()
        let handler = observations[name]
        lock.unlock()
        handler?()
    }
}
