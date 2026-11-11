import CoreMedia
import CoreVideo
import Metal
import MetalFX
import QuartzCore
import UIKit
import VideoToolbox

/// Hardware H.264 decoding via VideoToolbox, straight to Metal-compatible NV12 pixel buffers.
final class H264Decoder {
    private var session: VTDecompressionSession?
    private var format: CMFormatDescription?

    /// Called on VideoToolbox's thread with each decoded frame.
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// Called when a frame can't be decoded (e.g. missing keyframe) so the caller can ask for one.
    var onError: (() -> Void)?

    func reset() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        format = nil
    }

    func decode(_ sample: CMSampleBuffer) {
        guard let fmt = CMSampleBufferGetFormatDescription(sample) else { return }
        if session == nil || format == nil || !CMFormatDescriptionEqual(fmt, otherFormatDescription: format!) {
            createSession(fmt)
        }
        guard let session else { return }
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [], infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, _, _ in
            if status == noErr, let imageBuffer {
                self?.onFrame?(imageBuffer)
            } else if status != noErr {
                self?.onError?()
            }
        }
        if status != noErr {
            onError?()
        }
    }

    private func createSession(_ fmt: CMFormatDescription) {
        reset()
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var s: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: fmt,
            decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &s
        )
        guard status == noErr, let s else { return }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = s
        format = fmt
    }
}

enum Upscaler: String, CaseIterable {
    case metalfx, lanczos, bicubic, bilinear, integer

    var label: String {
        switch self {
        case .metalfx: return "MetalFX (FSR-style)"
        case .lanczos: return "Lanczos-3"
        case .bicubic: return "Bicubic"
        case .bilinear: return "Bilinear"
        case .integer: return "Integer (pixel-perfect)"
        }
    }
}

/// Render settings, read on the render thread.
struct RenderSettings {
    var upscaler: Upscaler = .metalfx
    /// FSR 1.0 RCAS sharpening strength, 0...1.
    var sharpness: Float = 0.25
    /// Luma-guided chroma upsampling (removes colour fringes on sharp edges).
    var chromaGuide = true
}

/// Turns decoded NV12 frames into a sharp picture at the screen's native pixel size:
/// 1. YUV -> RGB with luma-guided chroma upsampling (compute shader)
/// 2. upscale with the chosen algorithm into a texture at output size
/// 3. present with FSR 1.0 RCAS sharpening
final class MetalVideoView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private var textureCache: CVMetalTextureCache?
    private var convertPipeline: MTLComputePipelineState?
    private var upscalePipelines: [Upscaler: MTLRenderPipelineState] = [:]
    private var presentPipeline: MTLRenderPipelineState?

    // Only touched on renderQueue.
    private var rgbTexture: MTLTexture?
    private var scaledTexture: MTLTexture?
    private var scaler: MTLFXSpatialScaler?
    private var texturesKey = [Int]()

    private let renderQueue = DispatchQueue(label: "video.render", qos: .userInteractive)
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var renderScheduled = false
    private var drawableSize = CGSize.zero
    private var _settings = RenderSettings()

    var settings: RenderSettings {
        get { lock.lock(); defer { lock.unlock() }; return _settings }
        set {
            lock.lock()
            _settings = newValue
            lock.unlock()
            redraw()
        }
    }

    var isMetalFXSupported: Bool {
        guard let device else { return false }
        return MTLFXSpatialScalerDescriptor.supportsDevice(device)
    }

    override init(frame: CGRect) {
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = true
        backgroundColor = .black
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.maximumDrawableCount = 2 // lowest latency
        setUpPipelines()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func setUpPipelines() {
        guard let device, let library = device.makeDefaultLibrary() else { return }
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        if let fn = library.makeFunction(name: "yuvToRgb") {
            convertPipeline = try? device.makeComputePipelineState(function: fn)
        }
        func pipeline(_ fragment: String, format: MTLPixelFormat) -> MTLRenderPipelineState? {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "fullscreenVertex")
            desc.fragmentFunction = library.makeFunction(name: fragment)
            desc.colorAttachments[0].pixelFormat = format
            return try? device.makeRenderPipelineState(descriptor: desc)
        }
        upscalePipelines[.bilinear] = pipeline("upscaleBilinear", format: .rgba8Unorm)
        upscalePipelines[.bicubic] = pipeline("upscaleBicubic", format: .rgba8Unorm)
        upscalePipelines[.lanczos] = pipeline("upscaleLanczos", format: .rgba8Unorm)
        upscalePipelines[.integer] = pipeline("upscaleNearest", format: .rgba8Unorm)
        presentPipeline = pipeline("presentRCAS", format: .bgra8Unorm)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? UIScreen.main.scale
        metalLayer.contentsScale = scale
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        metalLayer.drawableSize = size
        lock.lock()
        drawableSize = size
        lock.unlock()
        redraw()
    }

    /// Thread-safe. Only the newest frame is rendered if frames arrive faster than we can draw.
    func display(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        latest = pixelBuffer
        lock.unlock()
        redraw()
    }

    func clear() {
        lock.lock()
        latest = nil
        lock.unlock()
    }

    /// Re-render the latest frame (e.g. after a settings or size change).
    private func redraw() {
        lock.lock()
        let schedule = !renderScheduled && latest != nil
        if schedule { renderScheduled = true }
        lock.unlock()
        if schedule {
            renderQueue.async { [weak self] in self?.renderLatest() }
        }
    }

    private func renderLatest() {
        lock.lock()
        let pb = latest
        let target = drawableSize
        let settings = _settings
        renderScheduled = false
        lock.unlock()
        guard let pb, target.width > 0, target.height > 0 else { return }
        render(pb, target: target, settings: settings)
    }

    /// The CVMetalTexture must stay alive until the GPU is done reading the MTLTexture.
    private func texture(_ pb: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> (MTLTexture, CVMetalTexture)? {
        guard let textureCache else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(pb, plane)
        let h = CVPixelBufferGetHeightOfPlane(pb, plane)
        var cvTex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pb, nil, format, w, h, plane, &cvTex)
        guard let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else { return nil }
        return (tex, cvTex)
    }

    private func prepareTextures(videoW: Int, videoH: Int, outW: Int, outH: Int, metalFX: Bool) {
        guard let device else { return }
        let key = [videoW, videoH, outW, outH, metalFX ? 1 : 0]
        if key == texturesKey, rgbTexture != nil, scaledTexture != nil { return }
        texturesKey = key
        scaler = nil

        if metalFX {
            let d = MTLFXSpatialScalerDescriptor()
            d.inputWidth = videoW
            d.inputHeight = videoH
            d.outputWidth = outW
            d.outputHeight = outH
            d.colorTextureFormat = .rgba8Unorm
            d.outputTextureFormat = .rgba8Unorm
            d.colorProcessingMode = .perceptual // the RGB values are gamma-encoded, not linear
            scaler = d.makeSpatialScaler(device: device)
        }

        let rgbDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: videoW, height: videoH, mipmapped: false
        )
        rgbDesc.usage = [.shaderRead, .shaderWrite]
        if let scaler { rgbDesc.usage.formUnion(scaler.colorTextureUsage) }
        rgbDesc.storageMode = .private
        rgbTexture = device.makeTexture(descriptor: rgbDesc)

        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: outW, height: outH, mipmapped: false
        )
        outDesc.usage = [.shaderRead, .renderTarget]
        if let scaler { outDesc.usage.formUnion(scaler.outputTextureUsage) }
        outDesc.storageMode = .private
        scaledTexture = device.makeTexture(descriptor: outDesc)
    }

    private func render(_ pb: CVPixelBuffer, target: CGSize, settings: RenderSettings) {
        guard let queue, let convertPipeline, let presentPipeline,
              let yPlane = texture(pb, plane: 0, format: .r8Unorm),
              let cPlane = texture(pb, plane: 1, format: .rg8Unorm) else { return }
        let (yTex, yRef) = yPlane
        let (cTex, cRef) = cPlane
        let videoW = CVPixelBufferGetWidth(pb)
        let videoH = CVPixelBufferGetHeight(pb)
        let outW = Int(target.width), outH = Int(target.height)
        var upscaler = settings.upscaler
        if upscaler == .metalfx && !isMetalFXSupported { upscaler = .lanczos }
        // Native resolution (extend mode): copy pixels 1:1; upscaling or sharpening would only hurt.
        if videoW == outW && videoH == outH { upscaler = .integer }
        prepareTextures(videoW: videoW, videoH: videoH, outW: outW, outH: outH, metalFX: upscaler == .metalfx)
        guard let rgbTexture, let scaledTexture, let cmd = queue.makeCommandBuffer() else { return }

        // 1. YUV -> RGB at video resolution
        if let enc = cmd.makeComputeCommandEncoder() {
            enc.setComputePipelineState(convertPipeline)
            enc.setTexture(yTex, index: 0)
            enc.setTexture(cTex, index: 1)
            enc.setTexture(rgbTexture, index: 2)
            // sigma = 0.05 in normalized luma, tuned on a sharp-edge test pattern
            var inv2Sigma2: Float = settings.chromaGuide ? 1 / (2 * 0.05 * 0.05) : 0
            enc.setBytes(&inv2Sigma2, length: MemoryLayout<Float>.size, index: 0)
            let tg = MTLSize(width: 16, height: 16, depth: 1)
            let groups = MTLSize(width: (videoW + 15) / 16, height: (videoH + 15) / 16, depth: 1)
            enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
            enc.endEncoding()
        }

        // 2. Upscale to the output's native pixel size
        if upscaler == .metalfx, let scaler {
            scaler.colorTexture = rgbTexture
            scaler.outputTexture = scaledTexture
            scaler.inputContentWidth = videoW
            scaler.inputContentHeight = videoH
            scaler.encode(commandBuffer: cmd)
        } else if let pipeline = upscalePipelines[upscaler] {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = scaledTexture
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            if let enc = cmd.makeRenderCommandEncoder(descriptor: pass) {
                enc.setRenderPipelineState(pipeline)
                enc.setFragmentTexture(rgbTexture, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
        }

        // 3. Sharpen (FSR 1.0 RCAS) and present
        guard let drawable = metalLayer.nextDrawable() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        if let enc = cmd.makeRenderCommandEncoder(descriptor: pass) {
            enc.setRenderPipelineState(presentPipeline)
            enc.setFragmentTexture(scaledTexture, index: 0)
            // pixel-perfect output shouldn't be sharpened
            var sharpness: Float = upscaler == .integer ? 0 : settings.sharpness
            enc.setFragmentBytes(&sharpness, length: MemoryLayout<Float>.size, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        cmd.present(drawable)
        cmd.addCompletedHandler { _ in
            // keep the decoded frame's textures alive until the GPU has finished with them
            _ = (yRef, cRef, pb)
        }
        cmd.commit()
    }
}
