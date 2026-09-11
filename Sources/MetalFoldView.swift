import Foundation
import Metal
import MetalKit
import AppKit

public struct Uniforms {
    public var imageSize: SIMD2<Float>
    public var cover: SIMD2<Float>
    public var aspect: Float
    public var turn: Float
    public var blurStrength: Float
    public var reflectionIntensity: Float
    public var sampleCount: Float
    public var motionBoost: Float
    
    public init(imageSize: SIMD2<Float> = .init(1, 1),
                cover: SIMD2<Float> = .init(1, 1),
                aspect: Float = 1.0,
                turn: Float = 0.0,
                blurStrength: Float = 1.0,
                reflectionIntensity: Float = 1.0,
                sampleCount: Float = 32.0,
                motionBoost: Float = 0.0) {
        self.imageSize = imageSize
        self.cover = cover
        self.aspect = aspect
        self.turn = turn
        self.blurStrength = blurStrength
        self.reflectionIntensity = reflectionIntensity
        self.sampleCount = sampleCount
        self.motionBoost = motionBoost
    }
}

public final class MetalFoldView: MTKView, MTKViewDelegate {
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var samplerState: MTLSamplerState?
    
    private var currentTexture: MTLTexture?
    private var imageSize: SIMD2<Float> = .init(1920, 1080)
    
    public var currentTurn: Float = 0.0
    public var blurStrength: Float = 0.5
    public var reflectionIntensity: Float = 0.0
    /// Velocity boost snapshot, written on main by OverlayWindowController.
    /// draw(in:) is @MainActor in practice (MTKView marshals there), so this
    /// is main-confined rather than cross-thread — the snapshot still earns
    /// its keep by decoupling sampling cadence from render cadence and by
    /// keeping LidSensor reads out of frame encoding.
    public var motionBoost: Float = 0.0

    // MARK: - Adaptive quality (close path only)

    /// 12 taps near open, 20 mid-fold, 32 on deep/fast close. Matches shader clamp.
    static func adaptiveSampleCount(turn: Float) -> Float {
        if turn < 0.20 { return 12.0 }
        if turn < 0.60 { return 20.0 }
        return 32.0
    }

    /// Velocity-aware boost in blur-radius units. Dead-zoned + clamped so HID
    /// jitter at rest adds nothing and fast slams stay silky, never mushy.
    /// Call on main only (reads LidSensor); result is snapshotted into
    /// motionBoost for draw().
    static func velocityBlurBoost() -> Float {
        let v = abs(LidSensor.shared.smoothedVelocity) // deg/sec
        guard v > 30.0 else { return 0.0 }
        return Float(min((v - 30.0) * 0.02, 12.0))
    }

    /// Resume the display link for active folding. Cadence matches the panel:
    /// 120fps on ProMotion internal, 60 on the 60Hz externals most desks use
    /// (half the drawable acquisitions + fragment cost for frames the panel
    /// never shows). Set once here — never mutated mid-frame. Called on show.
    /// Resolves the screen from NSScreen.main, not window.screen: resume runs
    /// before orderFront, when the window has no screen yet (nil → 60 would
    /// pin the ProMotion first impression to half cadence).
    func resumeRendering() {
        let panelMax = NSScreen.main?.maximumFramesPerSecond ?? 60
        preferredFramesPerSecond = min(120, max(30, panelMax))
        if isPaused {
            isPaused = false
        }
    }

    /// Full suspend: 0fps floor. isPaused stops drawable acquisition and
    /// orderOut (caller) removes the window from the compositor scene graph —
    /// those are the real wins. Note: releaseDrawables only frees the
    /// depth/multisample textures (we use neither), NOT the CAMetalLayer
    /// drawable pool. The last fold texture is deliberately KEPT across hide:
    /// it is seconds old and is the covering first frame on next show, while
    /// a fresh capture uploads async — nil-ing it traded a stale frame for a
    /// black flash the async reload cannot cover in time.
    func suspendRendering() {
        isPaused = true
        releaseDrawables()
    }
    
    public init(frame: CGRect) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this Mac")
        }
        super.init(frame: frame, device: device)
        commonInit()
    }
    
    required init(coder: NSCoder) {
        super.init(coder: coder)
        if self.device == nil {
            self.device = MTLCreateSystemDefaultDevice()
        }
        commonInit()
    }
    
    private func commonInit() {
        guard let dev = self.device else { return }
        
        self.commandQueue = dev.makeCommandQueue()
        self.delegate = self
        self.colorPixelFormat = .bgra8Unorm
        self.clearColor = MTLClearColor(red: 0.003, green: 0.004, blue: 0.005, alpha: 1.0)
        // Drawable is render-target-only (never sampled) — lets CAMetalLayer
        // use the TBDR-optimized path. Parked state is fully suspended (0fps).
        self.framebufferOnly = true
        self.enableSetNeedsDisplay = false
        self.preferredFramesPerSecond = 120
        self.isPaused = true
        
        // Sampler
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.mipFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        self.samplerState = dev.makeSamplerState(descriptor: samplerDesc)
        
        buildPipeline()
    }
    
    private func buildPipeline() {
        guard let dev = self.device else { return }
        
        var library: MTLLibrary?
        
        // Try to load compiled metallib first (check bundle for current class, then main)
        let bundle = Bundle(for: Self.self)
        if let libUrl = bundle.url(forResource: "default", withExtension: "metallib") ?? Bundle.main.url(forResource: "default", withExtension: "metallib") {
            library = try? dev.makeLibrary(URL: libUrl)
        }
        
        if library == nil {
            library = dev.makeDefaultLibrary()
        }
        
        // If still nil, compile from source file directly (bundle-relative only, no hardcoded dev paths)
        if library == nil {
            var possiblePaths: [String] = [
                Bundle.main.bundlePath + "/Contents/Resources/FoldShaders.metal",
                Bundle.main.bundlePath + "/FoldShaders.metal"
            ]
            if let classBundlePath = Bundle(for: Self.self).path(forResource: "FoldShaders", ofType: "metal") {
                possiblePaths.insert(classBundlePath, at: 0)
            }
            for p in possiblePaths {
                if let source = try? String(contentsOfFile: p, encoding: .utf8) {
                    library = try? dev.makeLibrary(source: source, options: nil)
                    if library != nil { break }
                }
            }
        }
        
        guard let lib = library else {
            print("[MetalFoldView] Failed to find or compile Metal library.")
            return
        }
        
        let vertexFunc = lib.makeFunction(name: "foldVertex")
        let fragmentFunc = lib.makeFunction(name: "foldFragment")
        
        let pipeDesc = MTLRenderPipelineDescriptor()
        pipeDesc.vertexFunction = vertexFunc
        pipeDesc.fragmentFunction = fragmentFunc
        pipeDesc.colorAttachments[0].pixelFormat = self.colorPixelFormat
        
        self.pipelineState = try? dev.makeRenderPipelineState(descriptor: pipeDesc)
    }
    
    // Monotonic generation: drops stale uploads when captures overlap.
    private var textureGeneration: UInt64 = 0

    // Serial throughput queue: bounds memory to one in-flight upload and keeps
    // bulk work off both main and the global pool. QoS .utility, never blocking.
    private let uploadQueue = DispatchQueue(label: "com.mactilt.upload", qos: .utility)

    public var hasTexture: Bool { currentTexture != nil }

    /// Upload a capture to the GPU. Decode + staging + blit all run on the
    /// serial upload queue; only the finished-texture assignment hops to main.
    /// One command buffer, one queue: copy + mipgen are ordered by submission,
    /// published in addCompletedHandler. No waitUntilCompleted anywhere.
    /// draw() holds the texture for the frame, so swapping is safe.
    public func updateImage(_ cgImage: CGImage) {
        guard let dev = self.device, let cq = self.commandQueue else { return }

        textureGeneration &+= 1
        let generation = textureGeneration
        let width = cgImage.width
        let height = cgImage.height

        uploadQueue.async { [weak self] in
            guard let self else { return }
            // Shader samples LOD 0..1.85 only — 3 levels, not the full ~11.
            let levels = 3

            // BGRA storage everywhere (not RGBA): the warm-stream path maps
            // IOSurface frames that ARE BGRA, and blit copies require
            // identical formats. Sampling is unaffected — the GPU swizzles to
            // RGBA-ordered float4 on sample, so the shader is untouched.
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: true
            )
            desc.mipmapLevelCount = levels
            desc.usage = [.shaderRead]
            desc.storageMode = .private

            // Stage through a shared CPU-visible texture, then GPU-side blit
            // into private storage — replace() runs on CPU, so it targets the
            // staging texture, never renderable memory.
            let stageDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            stageDesc.usage = [.shaderRead]
            stageDesc.storageMode = .shared

            guard let texture = dev.makeTexture(descriptor: desc),
                  let staging = dev.makeTexture(descriptor: stageDesc) else { return }

            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bytesPerRow = width * 4
            let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return }

            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let data = context.data else { return }
            staging.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: data,
                bytesPerRow: bytesPerRow
            )

            guard let cb = cq.makeCommandBuffer(),
                  let copy = cb.makeBlitCommandEncoder() else { return }
            copy.copy(from: staging, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: width, height: height, depth: 1),
                      to: texture, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            copy.endEncoding()
            guard let mips = cb.makeBlitCommandEncoder() else { return }
            mips.generateMipmaps(for: texture)
            mips.endEncoding()
            // Publish on completion: assignment lands on main only for the
            // newest generation; older overlapping uploads are discarded.
            cb.addCompletedHandler { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.textureGeneration == generation else { return }
                    self.imageSize = SIMD2<Float>(Float(width), Float(height))
                    self.currentTexture = texture
                }
            }
            cb.commit()
        }
    }

    /// Zero-copy fast path for warm-stream frames: blit the IOSurface texture
    /// straight into our private mipmapped texture. Skips CG decode, context
    /// draw, and staging entirely — the two full-frame CPU passes vanish.
    /// Same single-buffer, single-queue, generation-guarded ordering proof as
    /// updateImage. keeper is the CVMetalTexture container: retained through
    /// GPU completion (not just the async block), because the MTLTexture is
    /// an interior mapping that dies with its container.
    public func updateStreamTexture(_ source: MTLTexture, width: Int, height: Int, keeper: AnyObject) {
        guard let cq = self.commandQueue else { return }
        let copyWidth = min(width, source.width)
        let copyHeight = min(height, source.height)
        guard copyWidth > 0, copyHeight > 0 else { return }
        textureGeneration &+= 1
        let generation = textureGeneration

        uploadQueue.async { [weak self, keeper] in
            guard let self else { return }
            guard let dev = self.device else { return }
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: copyWidth,
                height: copyHeight,
                mipmapped: true
            )
            desc.mipmapLevelCount = 3
            desc.usage = [.shaderRead]
            desc.storageMode = .private
            guard let texture = dev.makeTexture(descriptor: desc),
                  let cb = cq.makeCommandBuffer(),
                  let copy = cb.makeBlitCommandEncoder() else { return }
            copy.copy(from: source, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: copyWidth, height: copyHeight, depth: 1),
                      to: texture, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            copy.endEncoding()
            guard let mips = cb.makeBlitCommandEncoder() else { return }
            mips.generateMipmaps(for: texture)
            mips.endEncoding()
            // keeper captured through completion: the source mapping must
            // outlive the GPU work, not just the CPU-side encoding.
            cb.addCompletedHandler { [weak self, keeper] _ in
                _ = keeper
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.textureGeneration == generation else { return }
                    self.imageSize = SIMD2<Float>(Float(copyWidth), Float(copyHeight))
                    self.currentTexture = texture
                }
            }
            cb.commit()
        }
    }
    
    // MARK: - MTKViewDelegate
    
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    
    public func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let renderPassDesc = view.currentRenderPassDescriptor,
              let pipeline = self.pipelineState,
              let texture = self.currentTexture,
              let cq = self.commandQueue,
              let cb = cq.makeCommandBuffer(),
              let encoder = cb.makeRenderCommandEncoder(descriptor: renderPassDesc) else {
            return
        }
        
        let viewSize = view.drawableSize
        let aspect = Float(viewSize.width / max(1.0, viewSize.height))
        let imgAspect = imageSize.x / max(1.0, imageSize.y)
        
        let cover = SIMD2<Float>(
            min(1.0, aspect / imgAspect),
            min(1.0, imgAspect / aspect)
        )
        
        var uniforms = Uniforms(
            imageSize: imageSize,
            cover: cover,
            aspect: aspect,
            turn: currentTurn,
            blurStrength: blurStrength,
            reflectionIntensity: reflectionIntensity,
            sampleCount: Self.adaptiveSampleCount(turn: currentTurn),
            motionBoost: motionBoost
        )
        
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        
        cb.present(drawable)
        cb.commit()
    }
}
