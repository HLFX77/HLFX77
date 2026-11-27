import Foundation
import Network

/// TLS-encrypted connection wrapper exchanging length-prefixed `SignalingMessage` frames.
public final class TLSSignalingConnection {
    public let id: UUID = UUID()
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let decoder = LengthPrefixedFrameCodec.FrameDecoder()
    private let stateLock = NSLock()
    private var isClosed = false

    public var onReady: (() -> Void)?
    public var onMessage: ((SignalingMessage) -> Void)?
    public var onDisconnect: ((Error?) -> Void)?

    public var remoteHostString: String? {
        switch connection.endpoint {
        case .hostPort(let host, _):
            let raw: String
            switch host {
            case .ipv4(let address):
                let bytes = address.rawValue
                if bytes.count == 4 {
                    raw = bytes.map { String($0) }.joined(separator: ".")
                } else {
                    raw = address.debugDescription
                }
            case .ipv6(let address):
                raw = address.debugDescription
            case .name(let name, _):
                raw = name
            @unknown default:
                raw = "\(host)"
            }
            return raw.split(separator: "%").first.map(String.init) ?? raw
        default:
            return nil
        }
    }

    /// Outbound TLS-PSK client connection to a remote LAN host and port.
    public init(host: String, port: UInt16, pskSecret: Data? = nil, identity: Data? = nil) {
        self.queue = DispatchQueue(label: "com.lanscreen.tls-conn.\(id.uuidString)", qos: .userInteractive)
        let parameters = TLSPskConfiguration.makeClientParameters(pskSecret: pskSecret, identity: identity)
        let endpointPort = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(integerLiteral: AppConstants.signalingPort)
        self.connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters)
    }

    /// Inbound accepted `NWConnection` created by `TLSSignalingServer`.
    public init(acceptedConnection: NWConnection) {
        self.queue = DispatchQueue(label: "com.lanscreen.tls-conn.\(id.uuidString)", qos: .userInteractive)
        self.connection = acceptedConnection
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
                self.receiveNextChunk()
            case .failed(let error):
                self.handleClose(error: error)
            case .cancelled:
                self.handleClose(error: nil)
            case .waiting(let error):
                // Fail fast on unreachable local IP rather than hanging indefinitely.
                if case .posix(let code) = error, code == .ECONNREFUSED || code == .EHOSTUNREACH || code == .ENETUNREACH {
                    self.connection.cancel()
                    self.handleClose(error: error)
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    public func send(_ message: SignalingMessage, completion: ((Error?) -> Void)? = nil) {
        stateLock.lock()
        let closed = isClosed
        stateLock.unlock()
        guard !closed else {
            completion?(NSError(domain: "LANScreen.TLS", code: -1, userInfo: [NSLocalizedDescriptionKey: "Connexion fermée."]))
            return
        }

        do {
            let framedData = try LengthPrefixedFrameCodec.encode(message)
            connection.send(content: framedData, completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.handleClose(error: error)
                }
                completion?(error)
            })
        } catch {
            completion?(error)
        }
    }

    public func close() {
        stateLock.lock()
        let alreadyClosed = isClosed
        isClosed = true
        stateLock.unlock()

        guard !alreadyClosed else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private func receiveNextChunk() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                do {
                    let messages = try self.decoder.append(data)
                    for message in messages {
                        self.onMessage?(message)
                    }
                } catch {
                    self.handleClose(error: error)
                    return
                }
            }

            if let error {
                self.handleClose(error: error)
                return
            }

            if isComplete {
                self.handleClose(error: nil)
                return
            }

            self.stateLock.lock()
            let stillOpen = !self.isClosed
            self.stateLock.unlock()
            if stillOpen {
                self.receiveNextChunk()
            }
        }
    }

    private func handleClose(error: Error?) {
        stateLock.lock()
        let alreadyClosed = isClosed
        isClosed = true
        stateLock.unlock()

        guard !alreadyClosed else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
        onDisconnect?(error)
    }
}

/// TLS-PSK local Wi-Fi signaling listener bound to a fixed or OS-assigned ephemeral port.
public final class TLSSignalingServer {
    private let requestedPort: UInt16
    private let advertiseBonjour: Bool
    private let queue = DispatchQueue(label: "com.lanscreen.tls-server", qos: .userInteractive)
    private var listener: NWListener?

    public private(set) var boundPort: UInt16?
    public var onListening: ((UInt16) -> Void)?
    public var onListenerFailure: ((Error) -> Void)?
    public var onNewConnection: ((TLSSignalingConnection) -> Void)?

    public init(port: UInt16, advertiseBonjour: Bool = false) {
        self.requestedPort = port
        self.advertiseBonjour = advertiseBonjour
    }

    public func start() throws {
        stop()

        let parameters = TLSPskConfiguration.makeServerParameters()
        let nwListener: NWListener
        if requestedPort == 0 {
            nwListener = try NWListener(using: parameters)
        } else if let nwPort = NWEndpoint.Port(rawValue: requestedPort) {
            nwListener = try NWListener(using: parameters, on: nwPort)
        } else {
            throw NSError(domain: "LANScreen.TLS", code: -2, userInfo: [NSLocalizedDescriptionKey: "Port invalide."])
        }

        if advertiseBonjour {
            nwListener.service = NWListener.Service(type: AppConstants.bonjourServiceType)
        }

        nwListener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let activePort = nwListener.port?.rawValue ?? self.requestedPort
                self.boundPort = activePort
                self.onListening?(activePort)
            case .failed(let error):
                self.boundPort = nil
                self.onListenerFailure?(error)
            case .cancelled:
                self.boundPort = nil
            default:
                break
            }
        }

        nwListener.newConnectionHandler = { [weak self] accepted in
            let wrapped = TLSSignalingConnection(acceptedConnection: accepted)
            self?.onNewConnection?(wrapped)
        }

        self.listener = nwListener
        nwListener.start(queue: queue)
    }

    public func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        boundPort = nil
    }
}
