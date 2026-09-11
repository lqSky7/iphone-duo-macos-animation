import Foundation
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Metal
// Pre-concurrency framework: SCStream isn't Sendable-annotated. All stream
// handles are confined to outputQueue or published under lock — audited.
@preconcurrency import ScreenCaptureKit

/// Warm-stream zero-copy capture. Holds a persistent SCStream delivering
/// IOSurface-backed frames; takeLatestTexture maps the newest frame straight
/// into a Metal texture — no CG decode, no CGContext draw, no staging copy.
/// ~2 full-frame CPU passes and 50-200ms of show latency disappear versus the
/// one-shot path. Any failure → caller falls back to SCScreenshotManager.
///
/// Lifecycle: primed on lid pre-arm (stream is warm before the fold), kept
/// across shows, stopped 1.5s after hide. Idle cost when parked: the stop
/// timer plus a quiescent session — near-zero when static (.complete gate),
/// hard zero after the tail.
///
/// Synchronization: manually synchronized — all mutable state under `lock`
/// except lifecycle flags confined to `outputQueue`. Declared Sendable on
/// that basis; NSLock is never touched from an async context.
public final class StreamCapture: NSObject, @unchecked Sendable {
    public static let shared = StreamCapture()

    /// Kill switch: false forces the one-shot path everywhere. Flip without
    /// touching call sites if the stream ever misbehaves on a given machine.
    public static var fastPathEnabled = true

    private let lock = NSLock()
    private var stream: SCStream?
    private var running = false
    private var starting = false
    // Stream generation: stop/restart bump it so a warm-up that outlives its
    // regime (reconfig mid-start, stop-then-start race, delayed error) can
    // never publish or kill a successor.
    private var streamGeneration: UInt64 = 0
    private var latestPixelBuffer: CVPixelBuffer?
    private var textureCache: CVMetalTextureCache?
    private var cacheDevice: MTLDevice?
    private var stopWorkItem: DispatchWorkItem?
    private let outputQueue = DispatchQueue(label: "com.mactilt.stream-output", qos: .utility)

    private override init() {
        super.init()
    }

    // MARK: - Lifecycle (all state transitions on outputQueue)

    /// Start warming the stream. Cheap when already warm; no-op when disabled.
    public func prime() {
        guard Self.fastPathEnabled else { return }
        outputQueue.async { [weak self] in
            self?.startIfNeeded()
        }
    }

    /// Overlay is visible (or about to be): cancel any pending idle stop.
    public func noteVisible() {
        guard Self.fastPathEnabled else { return }
        outputQueue.async { [weak self] in
            guard let self else { return }
            self.stopWorkItem?.cancel()
            self.stopWorkItem = nil
            self.startIfNeeded()
        }
    }

    /// Overlay hidden: stop the stream after a short idle tail. 1.5s covers
    /// hysteresis-band jiggle re-shows (sub-second); anything longer parks a
    /// session for incidental hides. Disabled path stops now. Note: the tail
    /// bounds OUR retention only — SCK delivers change-driven frames, so a
    /// static desktop costs idle ticks, not encodes, until the stop lands.
    public func noteHidden() {
        guard Self.fastPathEnabled else {
            outputQueue.async { [weak self] in
                self?.stopWorkItem?.cancel()
                self?.stopWorkItem = nil
                self?.stopStream()
            }
            return
        }
        outputQueue.async { [weak self] in
            guard let self else { return }
            self.stopWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.stopStream()
            }
            self.stopWorkItem = item
            self.outputQueue.asyncAfter(deadline: .now() + 1.5, execute: item)
        }
    }

    /// Display set changed: the cached filter's geometry is stale. Tear down
    /// now (bumping the generation so the in-flight warm-up can't publish);
    /// the next prime/visible restarts against the new configuration.
    public func restart() {
        outputQueue.async { [weak self] in
            guard let self else { return }
            self.stopWorkItem?.cancel()
            self.stopWorkItem = nil
            self.lock.lock()
            self.streamGeneration &+= 1
            self.starting = false
            self.lock.unlock()
            self.stopStream()
        }
    }

    private func startIfNeeded() {
        guard !running && !starting else { return }
        guard ScreenCapture.shared.hasPermission() else { return }
        starting = true
        lock.lock()
        streamGeneration &+= 1
        let generation = streamGeneration
        lock.unlock()
        // Detached: startStream awaits with no locks held; completion hops
        // back to outputQueue where all flag mutation is confined, and
        // publishes only if its generation is still current.
        let queue = outputQueue
        Task.detached(priority: .utility) { [weak self] in
            let stream = await self?.startStream()
            queue.async { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let current = self.streamGeneration
                self.lock.unlock()
                guard generation == current else { return }
                self.starting = false
                if let stream {
                    self.lock.lock()
                    self.stream = stream
                    self.running = true
                    self.lock.unlock()
                } else {
                    self.lock.lock()
                    self.running = false
                    self.lock.unlock()
                }
            }
        }
    }

    /// Builds and starts the stream. Lock-free: touches no shared state, so
    /// it is safe to await. Returns the running stream for the caller to
    /// publish on outputQueue.
    private func startStream() async -> SCStream? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = ScreenCapture.preferredDisplay(from: content) else { return nil }
            let pid = NSRunningApplication.current.processIdentifier
            let excluded = content.windows.filter { $0.owningApplication?.processID == pid }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            // Half of native pixels: the fold shader provably cannot resolve
            // more (blur mix + LOD 1.85 cap over 3 mip levels), so full-res
            // would quadruple resident + encode + blit bytes for zero pixels.
            // Cursor stays out: a frozen cursor over live desktop reads as bug.
            // NSScreen is main-thread-only: resolve the scale on MainActor.
            let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2.0 }
            let config = SCStreamConfiguration()
            config.width = max(2, Int(Double(display.width) * Double(scale) * 0.5))
            config.height = max(2, Int(Double(display.height) * Double(scale) * 0.5))
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            // Documented queue floor is 3; below risks start-rejection on
            // stricter OS releases. Newest-only consumer + complete-gate mean
            // the extra resident frame (~6-12MB half-res) buys compliance.
            config.queueDepth = 3
            config.showsCursor = false
            config.capturesAudio = false
            config.pixelFormat = kCVPixelFormatType_32BGRA
            // Match the one-shot path's sRGB contract: two gamuts into one
            // untagged bgra8Unorm drawable would pop saturation at fold start
            // on wide-gamut panels. Neither path does HDR (correct for SDR).
            config.colorSpaceName = CGColorSpace.sRGB
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
            try await stream.startCapture()
            return stream
        } catch {
            return nil
        }
    }

    private func stopStream() {
        lock.lock()
        let stream = stream
        streamGeneration &+= 1
        lock.unlock()
        guard let stream else { return }
        // stopCapture can stall for seconds (documented WindowServer
        // behavior) — detached background task, never the caller.
        Task.detached(priority: .utility) {
            try? stream.removeStreamOutput(self, type: .screen)
            try? await stream.stopCapture()
        }
        lock.lock()
        self.stream = nil
        running = false
        latestPixelBuffer = nil
        // Release the pool the cache pins: retention without this grows
        // across start/stop cycles instead of recycling.
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
        lock.unlock()
    }

    // MARK: - Frame access

    /// Newest frame as a zero-copy Metal texture (IOSurface-backed). The
    /// returned keeper MUST be retained by the caller until its blit
    /// completes — the MTLTexture is an interior reference whose mapping
    /// lives and dies with the CVMetalTexture container. Nil while the
    /// stream warms or on any error: caller falls back to one-shot capture.
    /// Fast: lock + cache lookup only.
    public func takeLatestTexture(device: MTLDevice) -> (texture: MTLTexture, width: Int, height: Int, keeper: CVMetalTexture)? {
        lock.lock()
        guard let pixelBuffer = latestPixelBuffer else {
            lock.unlock()
            return nil
        }
        if cacheDevice !== device || textureCache == nil {
            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
            textureCache = cache
            cacheDevice = device
        }
        guard let cache = textureCache else {
            lock.unlock()
            return nil
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture
        )
        guard result == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            lock.unlock()
            return nil
        }
        lock.unlock()
        return (texture, width, height, cvTexture)
    }
}

// MARK: - SCStreamOutput + SCStreamDelegate

extension StreamCapture: SCStreamOutput, SCStreamDelegate {
    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              CMSampleBufferDataIsReady(sampleBuffer),
              Self.frameIsComplete(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // No copy: the buffer is retained here, the previous frame released.
        lock.lock()
        latestPixelBuffer = pixelBuffer
        lock.unlock()
    }

    /// Only .complete frames refresh the latest texture. .idle ("display
    /// didn't change" — the common parked-desktop case) would otherwise churn
    /// IOSurface refcounts and defeat cache recycling for zero new pixels.
    private static func frameIsComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw) else {
            return true
        }
        return status == .complete
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        outputQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            // Identity check: a delayed error from a superseded stream must
            // never kill its successor (restart/stop-start races).
            guard let current = self.stream, current === stream else {
                self.lock.unlock()
                return
            }
            self.running = false
            self.stream = nil
            self.latestPixelBuffer = nil
            self.lock.unlock()
        }
    }
}
