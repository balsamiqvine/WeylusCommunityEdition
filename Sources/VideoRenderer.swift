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

/// Converts decoded frames to RGB, upscales them with MetalFX to the view's native pixel size and
/// presents them. Falls back to plain linear filtering if MetalFX isn't available.
final class MetalVideoView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private var textureCache: CVMetalTextureCache?
    private var convertPipeline: MTLComputePipelineState?
    private var presentPipeline: MTLRenderPipelineState?

    // Recreated when the video or drawable size changes. Only touched on renderQueue.
    private var rgbTexture: MTLTexture?
    private var scaledTexture: MTLTexture?
    private var scaler: MTLFXSpatialScaler?
    private var scalerKey: (Int, Int, Int, Int) = (0, 0, 0, 0)

    private let renderQueue = DispatchQueue(label: "video.render", qos: .userInteractive)
    private var latest: CVPixelBuffer?
    private var renderScheduled = false
    private let lock = NSLock()
    private var drawableSize = CGSize.zero

    /// Use MetalFX upscaling (sharper) instead of linear filtering.
    var useMetalFX = true

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
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        desc.fragmentFunction = library.makeFunction(name: "presentFragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        presentPipeline = try? device.makeRenderPipelineState(descriptor: desc)
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
    }

    /// Thread-safe. Only the newest frame is rendered if frames arrive faster than we can draw.
    func display(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        latest = pixelBuffer
        let schedule = !renderScheduled
        renderScheduled = true
        lock.unlock()
        if schedule {
            renderQueue.async { [weak self] in self?.renderLatest() }
        }
    }

    func clear() {
        lock.lock()
        latest = nil
        lock.unlock()
    }

    private func renderLatest() {
        lock.lock()
        let pb = latest
        let target = drawableSize
        renderScheduled = false
        lock.unlock()
        guard let pb, target.width > 0, target.height > 0 else { return }
        render(pb, target: target)
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

    private func prepareTextures(videoW: Int, videoH: Int, outW: Int, outH: Int) {
        guard let device else { return }
        let wantScaler = useMetalFX && isMetalFXSupported && (outW != videoW || outH != videoH)
        let key = (videoW, videoH, wantScaler ? outW : 0, wantScaler ? outH : 0)
        if key == scalerKey, rgbTexture != nil { return }
        scalerKey = key
        scaler = nil
        scaledTexture = nil

        var scalerDesc: MTLFXSpatialScalerDescriptor?
        if wantScaler {
            let d = MTLFXSpatialScalerDescriptor()
            d.inputWidth = videoW
            d.inputHeight = videoH
            d.outputWidth = outW
            d.outputHeight = outH
            d.colorTextureFormat = .rgba8Unorm
            d.outputTextureFormat = .rgba8Unorm
            d.colorProcessingMode = .perceptual // the RGB values are gamma-encoded, not linear
            scaler = d.makeSpatialScaler(device: device)
            scalerDesc = d
        }

        let rgbDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: videoW, height: videoH, mipmapped: false
        )
        rgbDesc.usage = [.shaderRead, .shaderWrite]
        if let scaler { rgbDesc.usage.formUnion(scaler.colorTextureUsage) }
        rgbDesc.storageMode = .private
        rgbTexture = device.makeTexture(descriptor: rgbDesc)

        if let scaler, scalerDesc != nil {
            let outDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: outW, height: outH, mipmapped: false
            )
            outDesc.usage = scaler.outputTextureUsage.union(.shaderRead)
            outDesc.storageMode = .private
            scaledTexture = device.makeTexture(descriptor: outDesc)
        }
    }

    private func render(_ pb: CVPixelBuffer, target: CGSize) {
        guard let queue, let convertPipeline, let presentPipeline,
              let yPlane = texture(pb, plane: 0, format: .r8Unorm),
              let cPlane = texture(pb, plane: 1, format: .rg8Unorm) else { return }
        let (yTex, yRef) = yPlane
        let (cTex, cRef) = cPlane
        let videoW = CVPixelBufferGetWidth(pb)
        let videoH = CVPixelBufferGetHeight(pb)
        prepareTextures(videoW: videoW, videoH: videoH, outW: Int(target.width), outH: Int(target.height))
        guard let rgbTexture, let cmd = queue.makeCommandBuffer() else { return }

        // 1. YUV -> RGB at video resolution
        if let enc = cmd.makeComputeCommandEncoder() {
            enc.setComputePipelineState(convertPipeline)
            enc.setTexture(yTex, index: 0)
            enc.setTexture(cTex, index: 1)
            enc.setTexture(rgbTexture, index: 2)
            let tg = MTLSize(width: 16, height: 16, depth: 1)
            let groups = MTLSize(width: (videoW + 15) / 16, height: (videoH + 15) / 16, depth: 1)
            enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
            enc.endEncoding()
        }

        // 2. MetalFX upscale to the screen's native pixel size
        var source: MTLTexture = rgbTexture
        if let scaler, let scaledTexture {
            scaler.colorTexture = rgbTexture
            scaler.outputTexture = scaledTexture
            scaler.inputContentWidth = videoW
            scaler.inputContentHeight = videoH
            scaler.encode(commandBuffer: cmd)
            source = scaledTexture
        }

        // 3. Present (1:1 when upscaled, linear filtering otherwise)
        guard let drawable = metalLayer.nextDrawable() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        if let enc = cmd.makeRenderCommandEncoder(descriptor: pass) {
            enc.setRenderPipelineState(presentPipeline)
            enc.setFragmentTexture(source, index: 0)
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
