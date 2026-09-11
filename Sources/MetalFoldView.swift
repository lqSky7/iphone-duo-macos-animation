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
    
    public init(imageSize: SIMD2<Float> = .init(1, 1),
                cover: SIMD2<Float> = .init(1, 1),
                aspect: Float = 1.0,
                turn: Float = 0.0,
                blurStrength: Float = 1.0,
                reflectionIntensity: Float = 1.0) {
        self.imageSize = imageSize
        self.cover = cover
        self.aspect = aspect
        self.turn = turn
        self.blurStrength = blurStrength
        self.reflectionIntensity = reflectionIntensity
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
        self.framebufferOnly = false
        self.enableSetNeedsDisplay = false
        self.preferredFramesPerSecond = 120
        self.isPaused = false
        
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
        
        // If still nil, compile from source file directly
        if library == nil {
            var possiblePaths: [String] = [
                Bundle.main.path(forResource: "FoldShaders", ofType: "metal"),
                Bundle.main.resourcePath.map { "\($0)/FoldShaders.metal" },
                Bundle.main.bundlePath + "/Contents/Resources/FoldShaders.metal",
                Bundle.main.bundlePath + "/FoldShaders.metal",
                FileManager.default.currentDirectoryPath + "/Sources/FoldShaders.metal",
                FileManager.default.currentDirectoryPath + "/FoldShaders.metal"
            ].compactMap { $0 }
            
            if let execPath = Bundle.main.executablePath {
                let execDir = (execPath as NSString).deletingLastPathComponent
                possiblePaths.append(execDir + "/FoldShaders.metal")
                possiblePaths.append(execDir + "/../Resources/FoldShaders.metal")
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
    
    public func updateImage(_ cgImage: CGImage) {
        guard let dev = self.device else { return }
        
        let width = cgImage.width
        let height = cgImage.height
        imageSize = SIMD2<Float>(Float(width), Float(height))
        
        let levels = max(1, Int(floor(log2(Double(max(width, height))))))
        
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: true
        )
        desc.mipmapLevelCount = levels
        desc.usage = [.shaderRead, .renderTarget]
        
        guard let texture = dev.makeTexture(descriptor: desc) else { return }
        
        // Render CGImage into level 0
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        
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
        if let data = context.data {
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: data,
                bytesPerRow: bytesPerRow
            )
        }
        
        // Generate mipmaps using blit command encoder
        if let cq = self.commandQueue,
           let cb = cq.makeCommandBuffer(),
           let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            cb.commit()
        }
        
        self.currentTexture = texture
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
            reflectionIntensity: reflectionIntensity
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
