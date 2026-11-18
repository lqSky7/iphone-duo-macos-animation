import Foundation
import Metal
import MetalKit
import AppKit
import QuartzCore

public struct Uniforms {
    public var imageSize: SIMD2<Float>
    public var cover: SIMD2<Float>
    public var aspect: Float
    public var turn: Float
    public var blurStrength: Float
    public var reflectionIntensity: Float
    public var sampleCount: Float
    public var motionBoost: Float
    public var sideVoid: Float
    public var duoMode: Float    // 1 = Duo Mode, 0 = original fold
    public var startAngle: Float // lid angle (deg) where turn = 0
    public var endAngle: Float   // lid angle (deg) where turn = 1
    
    public init(imageSize: SIMD2<Float> = .init(1, 1),
                cover: SIMD2<Float> = .init(1, 1),
                aspect: Float = 1.0,
                turn: Float = 0.0,
                blurStrength: Float = 1.0,
                reflectionIntensity: Float = 1.0,
                sampleCount: Float = 32.0,
                motionBoost: Float = 0.0,
                sideVoid: Float = 1.0,
                duoMode: Float = 1.0,
                startAngle: Float = 115.0,
                endAngle: Float = 3.0) {
        self.imageSize = imageSize
        self.cover = cover
        self.aspect = aspect
        self.turn = turn
        self.blurStrength = blurStrength
        self.reflectionIntensity = reflectionIntensity
        self.sampleCount = sampleCount
        self.motionBoost = motionBoost
        self.sideVoid = sideVoid
        self.duoMode = duoMode
        self.startAngle = startAngle
        self.endAngle = endAngle
    }
}

/// Uniforms for the gaussian downsample pass (matches PyramidParams in FoldShaders.metal).
private struct PyramidParams {
    var srcTexel: SIMD2<Float>
    var srcLod: Float
    var pad: Float
}

public final class MetalFoldView: MTKView, MTKViewDelegate {
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var downsamplePipelineState: MTLRenderPipelineState?
    private var samplerState: MTLSamplerState?
    
    private var currentTexture: MTLTexture?
    private var imageSize: SIMD2<Float> = .init(1920, 1080)
    
    /// Target fold turn (0..1), pre-easing. Written per sensor tick on main;
    /// the render loop eases toward it once per displayed frame in draw(in:).
    public var currentTurn: Float = 0.0
    /// Follow responsiveness (rate constant of the exponential follow filter,
    /// rad/s equivalent of AppSettings.followSpeed). Snapshotted per tick by
    /// OverlayWindowController so draw() never touches AppSettings.
    public var followSpeed: Double = 16.0
    public var blurStrength: Float = 0.5
    public var reflectionIntensity: Float = 0.0
    /// How far the left/right edges fall into the void as the panel folds
    /// (horizontal parallax spread). 0 = the frozen frame keeps its full
    /// width, 1 = the physical projection, up to 2 = exaggerated. Snapshotted
    /// from AppSettings per tick by OverlayWindowController.
    public var sideVoid: Float = 1.0
    /// Velocity boost snapshot, written on main by OverlayWindowController.
    /// draw(in:) is @MainActor in practice (MTKView marshals there), so this
    /// is main-confined rather than cross-thread — the snapshot still earns
    /// its keep by decoupling sampling cadence from render cadence and by
    /// keeping LidSensor reads out of frame encoding.
    public var motionBoost: Float = 0.0

    // MARK: - Render-rate easing (the smoothness core)
    //
    // The eased fold value used for drawing. `currentTurn` above is only the
    // TARGET; the exponential follow filter (same physics as the old tick-side
    // easing, factor = 1 - exp(-dt * followSpeed)) runs HERE, once per
    // displayed frame, with the exact display-link dt. The old scheme eased on
    // a main-runloop Timer (10..120Hz, coalesce/jitter-prone) and the 120Hz
    // display link then re-rendered each timer value several times before
    // jumping to the next — temporal aliasing read as judder. Same transfer
    // function, same lag constant, sampled uniformly at render cadence.
    private var renderTurn: Float = 0.0
    /// Duo mode's spring velocity (turn/sec).
    private var renderVelocity: Float = 0.0
    private var lastDrawTime: CFTimeInterval = 0
    /// Render-side eased copy of motionBoost (τ ≈ 80ms). The per-tick
    /// velocity snapshot steps the blur radius in whole units mid-fold,
    /// which reads as focus pumping on real lid motion (preview holds it
    /// near zero, so it never showed there). Same treatment as the turn.
    private var renderMotionBoost: Float = 0.0

    // MARK: - Adaptive quality (close path only)

    /// Base tap count for a turn value: 12 near open, 20 mid-fold, 32 deep.
    private static func baseSampleCount(turn: Float) -> Float {
        if turn < 0.20 { return 12.0 }
        if turn < 0.60 { return 20.0 }
        return 32.0
    }

    private var lastSampleCount: Float = 12.0

    /// Hysteresis-banded adaptive tap count. A hard threshold at 0.20/0.60
    /// lets a turn value jittering around the boundary flip 12↔20 taps — and
    /// each flip subtly changes blur character, which reads as shimmer
    /// mid-fold. Rising: 0.20/0.60 (matches the old thresholds); falling:
    /// 0.16/0.56. Reset from the base table on every show (snap path).
    private func adaptiveSampleCount(turn: Float) -> Float {
        if lastSampleCount <= 12.0 {
            if turn >= 0.60 { lastSampleCount = 32.0 }
            else if turn >= 0.20 { lastSampleCount = 20.0 }
        } else if lastSampleCount <= 20.0 {
            if turn >= 0.60 { lastSampleCount = 32.0 }
            else if turn < 0.16 { lastSampleCount = 12.0 }
        } else if turn < 0.56 {
            lastSampleCount = (turn < 0.16) ? 12.0 : 20.0
        }
        return lastSampleCount
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
    /// Resolves the built-in panel, not window.screen: resume runs before
    /// orderFront, when the window has no screen yet (nil → 60 would pin the
    /// ProMotion first impression to half cadence). `NSScreen.screens` needs no
    /// window, and the built-in panel is the one being folded — the main
    /// screen's cadence is the wrong answer when an external monitor holds
    /// focus.
    func resumeRendering() {
        let panelMax = (DisplayTopology.builtInScreen() ?? NSScreen.main)?.maximumFramesPerSecond ?? 60
        preferredFramesPerSecond = min(120, max(30, panelMax))
        if isPaused {
            isPaused = false
        }
    }

    /// Seed for the next draw's eased fold value. While set, the first frame
    /// after a resume eases UP from this value instead of snapping to
    /// `currentTurn`. Used by the auto-release hand-back: the overlay returns
    /// with the fold at zero and grows into wherever the lid now is, rather
    /// than appearing already folded over a desktop that was sharp a moment
    /// ago.
    private var seededTurn: Float?

    /// Arm the next resume to start unfolding from `turn`. Ignored on a view
    /// that is already running — the seed only means anything for the first
    /// frame after a (re)start.
    func seedFold(from turn: Float) {
        seededTurn = turn
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
        // Invalidate the easing clock: the first draw after resume must SNAP
        // to the current target, never interpolate across the hidden gap.
        lastDrawTime = 0
        // A seed belongs to the show that armed it; a later, unrelated show
        // must not inherit it.
        seededTurn = nil
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

        // Gaussian pyramid downsample pipeline: same fullscreen-triangle
        // vertex stage, binomial 3x3 fragment. Built once, reused per upload.
        if let downsampleFunc = lib.makeFunction(name: "gaussianDownsampleFragment") {
            let downDesc = MTLRenderPipelineDescriptor()
            downDesc.vertexFunction = vertexFunc
            downDesc.fragmentFunction = downsampleFunc
            downDesc.colorAttachments[0].pixelFormat = self.colorPixelFormat
            self.downsamplePipelineState = try? dev.makeRenderPipelineState(descriptor: downDesc)
        }
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
            // 6-level gaussian pyramid (LOD 0..5) for the real blur.
            let levels = 6

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
            // .renderTarget: each mip level above 0 is rendered into by the
            // gaussian downsample passes (not generated by the box filter).
            desc.usage = [.shaderRead, .renderTarget]
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
            encodeGaussianPyramid(texture: texture, levels: levels, commandBuffer: cb)
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
            desc.mipmapLevelCount = 6
            desc.usage = [.shaderRead, .renderTarget]
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
            encodeGaussianPyramid(texture: texture, levels: 6, commandBuffer: cb)
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
    
    /// True gaussian blur pyramid: level k+1 = binomial 3x3 of level k at
    /// half resolution (σ doubles per level; 6 levels total). Rendered once
    /// per texture upload on this command buffer — consecutive passes write
    /// mip k while sampling mip k-1 of the same texture (different
    /// subresources, ordered across encoders by Metal's hazard tracking).
    /// Total cost ≈ 33% of one fullscreen pass, paid once per capture,
    /// never per frame. Replaces the old box-filter generateMipmaps, whose
    /// flat average-color blobs read as "fake blur" (opaque spread).
    private func encodeGaussianPyramid(texture: MTLTexture, levels: Int, commandBuffer cb: MTLCommandBuffer) {
        guard let pipe = downsamplePipelineState, let sampler = samplerState else { return }
        for level in 1..<levels {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = texture
            rpd.colorAttachments[0].level = level
            rpd.colorAttachments[0].loadAction = .dontCare
            rpd.colorAttachments[0].storeAction = .store
            guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
            let prevW = max(1, texture.width >> (level - 1))
            let prevH = max(1, texture.height >> (level - 1))
            var params = PyramidParams(
                srcTexel: SIMD2<Float>(1.0 / Float(prevW), 1.0 / Float(prevH)),
                srcLod: Float(level - 1),
                pad: 0
            )
            enc.setRenderPipelineState(pipe)
            enc.setFragmentTexture(texture, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.setFragmentBytes(&params, length: MemoryLayout<PyramidParams>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            enc.endEncoding()
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

        // Render-rate easing: advance the exponential follow filter toward
        // the target exactly once per displayed frame. Identical physics to
        // the previous tick-side easing (same τ = 1/followSpeed, same lead
        // prediction upstream) — only the sampling grid changes, from a
        // jittery 10..120Hz main-runloop timer to the uniform display-link
        // cadence. Snap on the first frame after (re)start; clamp dt so a
        // stall between frames can never produce a teleport.
        let now = CACurrentMediaTime()
        if lastDrawTime <= 0.0 {
            // A seed (auto-release hand-back) wins over the live fold value:
            // it is the whole point of arming one. Consumed here so it can
            // never leak into a later frame.
            renderTurn = seededTurn ?? currentTurn
            renderVelocity = 0.0
            seededTurn = nil
            renderMotionBoost = motionBoost
            lastSampleCount = Self.baseSampleCount(turn: renderTurn)
        } else {
            let dt = min(max(now - lastDrawTime, 0.0), 0.1)
            if dt > 0.0 {
                if AppSettings.shared.duoMode {
                    // Duo: critically damped spring. The sensor reports whole degrees, and a
                    // first-order filter turns each step into a velocity kick — invisible when
                    // the picture moves with the panel, a visible jolt when it stands still.
                    // ω = 2·followSpeed keeps the same average lag (2/ω vs 1/followSpeed).
                    let omega = Float(followSpeed * 2.0)
                    let k = omega * Float(dt)
                    let decay = 1.0 / (1.0 + k + 0.48 * k * k + 0.235 * k * k * k)
                    let change = renderTurn - currentTurn
                    let temp = (renderVelocity + omega * change) * Float(dt)
                    renderVelocity = (renderVelocity - omega * temp) * decay
                    renderTurn = currentTurn + (change + temp) * decay
                    if abs(currentTurn - renderTurn) < 0.0005 && abs(renderVelocity) < 0.005 {
                        renderTurn = currentTurn
                        renderVelocity = 0.0
                    }
                } else {
                    let factor = 1.0 - exp(-dt * followSpeed)
                    renderTurn += (currentTurn - renderTurn) * Float(factor)
                    if abs(currentTurn - renderTurn) < 0.0005 {
                        renderTurn = currentTurn
                    }
                }
                // Velocity blur boost eases per frame too: per-tick steps
                // in the blur radius read as focus pumping.
                let mbFactor = 1.0 - exp(-dt * 12.5) // τ ≈ 80ms
                renderMotionBoost += (motionBoost - renderMotionBoost) * Float(mbFactor)
            }
        }
        lastDrawTime = now

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
            turn: renderTurn,
            blurStrength: blurStrength,
            reflectionIntensity: reflectionIntensity,
            sampleCount: adaptiveSampleCount(turn: renderTurn),
            motionBoost: renderMotionBoost,
            sideVoid: sideVoid,
            duoMode: AppSettings.shared.duoMode ? 1.0 : 0.0,
            startAngle: Float(AppSettings.shared.startTiltAngle),
            endAngle: Float(AppSettings.shared.endTiltAngle)
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
