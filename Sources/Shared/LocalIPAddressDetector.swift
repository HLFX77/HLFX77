import Darwin
import Foundation
import Network

/// Detects the active local Wi-Fi IPv4 address and validates user-entered IPv4 addresses.
public enum LocalIPAddressDetector {
    /// Preferred iOS interface priority order: Wi-Fi (`en0`), secondary Ethernet/hotspot adapters.
    private static let preferredInterfaceOrder = ["en0", "en1", "en2", "bridge100"]

    /// Returns the primary local Wi-Fi IPv4 address (e.g., "192.168.1.37"), or `nil` if unavailable.
    public static func currentWiFiIPv4() -> String? {
        let interfaces = availableIPv4Interfaces()
        for preferred in preferredInterfaceOrder {
            if let match = interfaces.first(where: { $0.name == preferred }) {
                return match.address
            }
        }
        return interfaces.first(where: { $0.name.hasPrefix("en") })?.address
    }

    /// Enumerates all active, non-loopback IPv4 network interfaces on the device.
    public static func availableIPv4Interfaces() -> [(name: String, address: String)] {
        var result: [(name: String, address: String)] = []
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddrPointer) == 0, let firstAddr = ifaddrPointer else {
            return result
        }
        defer { freeifaddrs(ifaddrPointer) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let interface = pointer?.pointee {
            defer { pointer = interface.ifa_next }

            let flags = Int32(interface.ifa_flags)
            let isUpAndRunning = (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING)
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            guard isUpAndRunning, !isLoopback, let addr = interface.ifa_addr else {
                continue
            }

            guard addr.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            let interfaceName = String(cString: interface.ifa_name)
            // Exclude cellular (`pdp_ip*`) and VPN (`utun*`) interfaces so only LAN/Wi-Fi addresses are used.
            if interfaceName.hasPrefix("pdp_ip") || interfaceName.hasPrefix("utun") || interfaceName.hasPrefix("ipsec") {
                continue
            }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let addrLen = socklen_t(addr.pointee.sa_len)
            let status = getnameinfo(
                addr,
                addrLen,
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard status == 0 else { continue }

            let ipString = String(cString: hostname)
            if isValidIPv4(ipString) {
                result.append((name: interfaceName, address: ipString))
            }
        }

        return result
    }

    /// Normalizes common French/mobile keyboard punctuation quirks (commas, whitespace) into clean IPv4 text.
    public static func normalizeIPInput(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: " ", with: "")
    }

    /// Validates strict dotted-quad IPv4 format via POSIX `inet_pton`.
    public static func isValidIPv4(_ ip: String) -> Bool {
        let trimmed = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.split(separator: ".", omittingEmptySubsequences: false).count == 4 else {
            return false
        }
        var addr = in_addr()
        return trimmed.withCString { cString in
            inet_pton(AF_INET, cString, &addr) == 1
        }
    }

    /// Returns `true` when `ip` is a loopback (`127.x.x.x`) or unspecified (`0.0.0.0`) address.
    public static func isNonRoutableLocalAddress(_ ip: String) -> Bool {
        ip == "0.0.0.0" || ip.hasPrefix("127.")
    }
}

/// Observes Wi-Fi path transitions via `NWPathMonitor` and publishes updated local IPv4 addresses.
public final class WiFiNetworkMonitor: ObservableObject {
    @Published public private(set) var isWiFiConnected: Bool = false
    @Published public private(set) var currentIPv4: String?

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.lanscreen.wifi-monitor", qos: .utility)

    public init() {
        self.monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        self.currentIPv4 = LocalIPAddressDetector.currentWiFiIPv4()
        self.isWiFiConnected = self.currentIPv4 != nil
    }

    public func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let wifiAvailable = path.status == .satisfied && path.usesInterfaceType(.wifi)
            let detectedIP = LocalIPAddressDetector.currentWiFiIPv4()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isWiFiConnected = wifiAvailable || detectedIP != nil
                self.currentIPv4 = detectedIP
            }
        }
        monitor.start(queue: queue)
        refreshNow()
    }

    public func stop() {
        monitor.cancel()
    }

    public func refreshNow() {
        let detectedIP = LocalIPAddressDetector.currentWiFiIPv4()
        DispatchQueue.main.async { [weak self] in
            self?.currentIPv4 = detectedIP
            if detectedIP != nil {
                self?.isWiFiConnected = true
            }
        }
    }
}
