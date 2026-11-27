import CoreVideo
import Foundation
import ImageIO
import VideoToolbox

/// Pure geometry and rotation helpers shared between capture pipeline and unit tests.
public enum VideoGeometry {
    /// Computes aspect-preserving even dimensions capped at maxLongEdge (minimum 2x2 for H.264).
    public static func scaledEvenDimensions(width: Int, height: Int, maxLongEdge: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0, maxLongEdge >= 2 else {
            return (max(2, makeEven(width)), max(2, makeEven(height)))
        }

        let currentLongEdge = max(width, height)
        if currentLongEdge <= maxLongEdge {
            return (makeEven(width), makeEven(height))
        }

        let scale = Double(maxLongEdge) / Double(currentLongEdge)
        let scaledW = makeEven(Int((Double(width) * scale).rounded()))
        let scaledH = makeEven(Int((Double(height) * scale).rounded()))
        return (max(2, scaledW), max(2, scaledH))
    }

    /// Maps an EXIF / ReplayKit CGImagePropertyOrientation raw value to rotation degrees (0, 90, 180, 270).
    public static func rotationDegrees(forOrientationRawValue rawValue: UInt32?) -> Int {
        guard let rawValue, let orientation = CGImagePropertyOrientation(rawValue: rawValue) else {
            return 0
        }
        switch orientation {
        case .up, .upMirrored:
            return 0
        case .left, .leftMirrored:
            return 90
        case .down, .downMirrored:
            return 180
        case .right, .rightMirrored:
            return 270
        @unknown default:
            return 0
        }
    }

    private static func makeEven(_ value: Int) -> Int {
        let clamped = max(2, value)
        return clamped % 2 == 0 ? clamped : clamped - 1
    }
}

/// Drops excessive ReplayKit frames so CPU/RAM stay safely under the 50 MB extension budget.
public final class FrameRateLimiter {
    private let minIntervalSeconds: TimeInterval
    private var lastAcceptedTimestamp: TimeInterval = 0

    public init(targetFPS: Int) {
        let safeFPS = max(1, targetFPS)
        self.minIntervalSeconds = 1.0 / Double(safeFPS)
    }

    public func shouldProcessFrame(at timestamp: TimeInterval) -> Bool {
        if lastAcceptedTimestamp == 0 || (timestamp - lastAcceptedTimestamp) >= minIntervalSeconds {
            lastAcceptedTimestamp = timestamp
            return true
        }
        return false
    }

    public func reset() {
        lastAcceptedTimestamp = 0
    }
}

/// Hardware-accelerated VTPixelTransferSession + tiny CVPixelBufferPool resizer.
/// Keeps peak memory minimal inside ReplayKit's ~50 MB Broadcast Upload Extension sandbox.
public final class PixelBufferResizer {
    private var transferSession: VTPixelTransferSession?
    private var pixelBufferPool: CVPixelBufferPool?
    private var configuredWidth: Int = 0
    private var configuredHeight: Int = 0
    private var configuredFormat: OSType = 0

    public init() {
        var session: VTPixelTransferSession?
        if VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session) == noErr,
           let created = session {
            VTSessionSetProperty(
                created,
                key: kVTPixelTransferPropertyKey_ScalingMode,
                value: "Normal" as CFString
            )
            self.transferSession = created
        }
    }

    deinit {
        if let transferSession {
            VTPixelTransferSessionInvalidate(transferSession)
        }
    }

    /// Downscales sourceBuffer to fit maxLongEdge if larger, returning the original buffer when already within bounds.
    public func resizeIfNeeded(_ sourceBuffer: CVPixelBuffer, maxLongEdge: Int) -> CVPixelBuffer {
        let sourceWidth = CVPixelBufferGetWidth(sourceBuffer)
        let sourceHeight = CVPixelBufferGetHeight(sourceBuffer)
        let target = VideoGeometry.scaledEvenDimensions(
            width: sourceWidth,
            height: sourceHeight,
            maxLongEdge: maxLongEdge
        )

        if target.width == sourceWidth && target.height == sourceHeight {
            return sourceBuffer
        }

        guard let session = transferSession else {
            return sourceBuffer
        }

        let pixelFormat = CVPixelBufferGetPixelFormatType(sourceBuffer)
        guard let pool = ensurePool(width: target.width, height: target.height, pixelFormat: pixelFormat) else {
            return sourceBuffer
        }

        var outputBuffer: CVPixelBuffer?
        let createStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outputBuffer)
        guard createStatus == kCVReturnSuccess, let destination = outputBuffer else {
            return sourceBuffer
        }

        let transferStatus = VTPixelTransferSessionTransferImage(session, from: sourceBuffer, to: destination)
        return transferStatus == noErr ? destination : sourceBuffer
    }

    private func ensurePool(width: Int, height: Int, pixelFormat: OSType) -> CVPixelBufferPool? {
        if let pool = pixelBufferPool,
           configuredWidth == width,
           configuredHeight == height,
           configuredFormat == pixelFormat {
            return pool
        }

        pixelBufferPool = nil

        let poolAttributes: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: 3
        ]
        let pixelAttributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true
        ]

        var createdPool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            pixelAttributes as CFDictionary,
            &createdPool
        )

        guard status == kCVReturnSuccess, let createdPool else {
            return nil
        }

        self.pixelBufferPool = createdPool
        self.configuredWidth = width
        self.configuredHeight = height
        self.configuredFormat = pixelFormat
        return createdPool
    }
}
