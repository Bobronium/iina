//
//  ViewLayer.swift
//  iina
//
//  Created by lhc on 27/1/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import AVFoundation
import Cocoa
import CoreImage
import IOSurface
import OpenGL.GL
import OpenGL.GL3

let glVersions: [CGLOpenGLProfile] = [
    kCGLOGLPVersion_3_2_Core,
    kCGLOGLPVersion_Legacy
]

let glFormatBase: [CGLPixelFormatAttribute] = [
    kCGLPFAOpenGLProfile,
    kCGLPFAAccelerated,
    kCGLPFADoubleBuffer
]

let glFormatSoftwareBase: [CGLPixelFormatAttribute] = [
    kCGLPFAOpenGLProfile,
    kCGLPFARendererID,
    CGLPixelFormatAttribute(UInt32(kCGLRendererGenericFloatID)),
    kCGLPFADoubleBuffer
]

let glFormatOptional: [[CGLPixelFormatAttribute]] = [
    [kCGLPFABackingStore],
    [kCGLPFAAllowOfflineRenderers]
]

let glFormat10Bit: [CGLPixelFormatAttribute] = [
    kCGLPFAColorSize,
    _CGLPixelFormatAttribute(rawValue: 64),
    kCGLPFAColorFloat
]

let glFormatAutoGPU: [CGLPixelFormatAttribute] = [
    kCGLPFASupportsAutomaticGraphicsSwitching
]

let attributeLookUp: [UInt32: String] = [
    kCGLOGLPVersion_3_2_Core.rawValue: "kCGLOGLPVersion_3_2_Core",
    kCGLOGLPVersion_Legacy.rawValue: "kCGLOGLPVersion_Legacy",
    kCGLPFAOpenGLProfile.rawValue: "kCGLPFAOpenGLProfile",
    UInt32(kCGLRendererGenericFloatID): "kCGLRendererGenericFloatID",
    kCGLPFARendererID.rawValue: "kCGLPFARendererID",
    kCGLPFAAccelerated.rawValue: "kCGLPFAAccelerated",
    kCGLPFADoubleBuffer.rawValue: "kCGLPFADoubleBuffer",
    kCGLPFABackingStore.rawValue: "kCGLPFABackingStore",
    kCGLPFAColorSize.rawValue: "kCGLPFAColorSize",
    kCGLPFAColorFloat.rawValue: "kCGLPFAColorFloat",
    kCGLPFAAllowOfflineRenderers.rawValue: "kCGLPFAAllowOfflineRenderers",
    kCGLPFASupportsAutomaticGraphicsSwitching.rawValue: "kCGLPFASupportsAutomaticGraphicsSwitching"
]

/// Video layer for `VideoView`: presents frames mpv renders as tagged pixel buffers.
///
/// ```swift
/// videoLayer.colorimetry = mpv.videoColorimetry()!.presentable
/// videoLayer.showsHighDynamicRange = player.info.hdrEnabled
/// videoLayer.update(force: true)
/// ```
class ViewLayer: AVSampleBufferDisplayLayer {

  static var canShowHighDynamicRangeAsStandard: Bool {
    if #available(macOS 26.0, *) { return true }
    return false
  }

  private weak var videoView: VideoView!

  private let mpvGLQueue = DispatchQueue(label: "com.colliderli.iina.mpvgl", qos: .userInteractive)

  private let cglContext: CGLContextObj
  private let cglPixelFormat: CGLPixelFormatObj

  /// Accessed only on `mpvGLQueue` with the OpenGL context locked.
  private var framePool: VideoFramePool?

  /// Accessed only on `mpvGLQueue` with the OpenGL context locked.
  private lazy var frameEncoder: YCbCrEncoder? = usesCoreProfile ? YCbCrEncoder() : nil

  @Atomic var colorimetry = VideoColorimetry.standardDynamicRange

  var showsHighDynamicRange = true {
    didSet {
      guard #available(macOS 26.0, *) else { return }
      preferredDynamicRange = showsHighDynamicRange ? .high : .standard
    }
  }

  /// When `true` drawing will proceed even if mpv indicates nothing needs to be done.
  @Atomic private var forceDraw = false

  /// Indicates whether the view is being rendered as part of a live resizing operation.
  @Atomic var inLiveResize: Bool = false {
    didSet {
      update(force: true)
    }
  }

  override var bounds: CGRect {
    didSet {
      guard bounds.size != oldValue.size else { return }
      update(force: true)
    }
  }

  override var contentsScale: CGFloat {
    didSet {
      guard contentsScale != oldValue else { return }
      update(force: true)
    }
  }

  /// Returns an initialized `ViewLayer` object.
  /// - Parameter videoView: The view this layer will be associated with.
  init(_ videoView: VideoView) {
    self.videoView = videoView
    cglPixelFormat = ViewLayer.createPixelFormat(videoView.player)
    cglContext = ViewLayer.createContext(cglPixelFormat)
    super.init()
    autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
    backgroundColor = NSColor.black.cgColor
    // When resized but mpv hasn't rendered a new frame, the old content's aspect ratio should be preserved.
    videoGravity = .resizeAspectFill
  }

  /// Returns an initialized shadow copy of the given layer with custom instance variables copied from `layer`.
  ///
  /// This initializer will be used when `MainWindowController.windowDidChangeBackingProperties` changes
  /// [contentsScale](https://developer.apple.com/documentation/quartzcore/calayer/1410746-contentsscale).
  /// To trigger this start IINA playing on an external monitor with a different scale factor with a MacBook in closed clamshell mode then
  /// unplug the external monitor.
  /// - Parameter layer: The layer from which custom fields should be copied.
  override init(layer: Any) {
    let previousLayer = layer as! ViewLayer
    videoView = previousLayer.videoView
    cglPixelFormat = previousLayer.cglPixelFormat
    cglContext = previousLayer.cglContext
    super.init(layer: layer)
    colorimetry = previousLayer.colorimetry
    showsHighDynamicRange = previousLayer.showsHighDynamicRange
    Logger.log("Created view layer shadow copy")
  }

  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Draw

  func update(force: Bool = false) {
    mpvGLQueue.async { [self] in
      if force { forceDraw = true }
      renderFrameIfNeeded()
    }
  }

  /// Release the OpenGL objects backing rendered frames.
  /// - Important: The OpenGL context must be locked by the caller.
  func releaseFrames() {
    framePool?.deleteFramebuffers()
    framePool = nil
  }

  private func renderFrameIfNeeded() {
    guard let mpv = videoView.player.mpv else { return }
    // The OpenGL context must always be locked before locking the isUninited lock to avoid deadlocks.
    CGLLockContext(cglContext)
    CGLSetCurrentContext(cglContext)
    defer { CGLUnlockContext(cglContext) }
    videoView.$isUninited.withReadLock() { isUninited in
      guard !isUninited, let renderContext = mpv.mpvRenderContext else { return }
      let forced = forceDraw
      forceDraw = false
      guard mpv.shouldRenderUpdateFrame() || forced else { return }
      guard let pool = currentFramePool(), let frame = pool.nextFrame() else { return }
      let colorimetry = colorimetry
      render(renderContext, into: frame)
      pool.finish(frame, matrix: colorimetry.ycbcrMatrix)
      CVBufferSetAttachments(frame.pixelBuffer, colorimetry.pixelBufferAttachments(for: pool.encoding) as CFDictionary,
                             .shouldPropagate)
      if pool.encoding == .ycbcr {
        ViewLayer.attachDolbyVision(mpv.renderedFrameDolbyVisionRPU(), compatibilityID: colorimetry.dolbyVisionCompatibilityID,
                                    to: frame.pixelBuffer)
      }
      present(frame.pixelBuffer)
      deliverPendingSnapshot(of: frame.pixelBuffer)
    }
  }

  private var pixelSize: (width: Int, height: Int) {
    let size = bounds.size
    return (Int((size.width * contentsScale).rounded()), Int((size.height * contentsScale).rounded()))
  }

  private var usesCoreProfile: Bool {
    var profile: GLint = 0
    CGLDescribePixelFormat(cglPixelFormat, 0, kCGLPFAOpenGLProfile, &profile)
    return profile != GLint(kCGLOGLPVersion_Legacy.rawValue)
  }

  private func currentFramePool() -> VideoFramePool? {
    let size = pixelSize
    guard size.width > 0, size.height > 0 else { return nil }
    if framePool?.width != size.width || framePool?.height != size.height {
      releaseFrames()
      framePool = VideoFramePool(width: size.width, height: size.height, encoding: .ycbcr, encoder: frameEncoder,
                                 context: cglContext)
        ?? VideoFramePool(width: size.width, height: size.height, encoding: .rgb, encoder: nil, context: cglContext)
    }
    return framePool
  }

  private static let dolbyVisionRPUKey = "DolbyVisionRPUData" as CFString
  private static let dolbyCompatibilityIDKey = "DolbyCompatibilityID" as CFString

  private static func attachDolbyVision(_ rpu: Data?, compatibilityID: Int?, to pixelBuffer: CVPixelBuffer) {
    guard let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
    guard let rpu, let compatibilityID else {
      IOSurfaceRemoveValue(surface, dolbyVisionRPUKey)
      IOSurfaceRemoveValue(surface, dolbyCompatibilityIDKey)
      return
    }
    let tags: [CFString: CFTypeRef] = [dolbyVisionRPUKey: rpu as CFData,
                                       dolbyCompatibilityIDKey: String(compatibilityID) as CFString]
    for (key, value) in tags {
      CVBufferSetAttachment(pixelBuffer, key, value, .shouldPropagate)
      IOSurfaceSetValue(surface, key, value)
    }
  }

  private func render(_ renderContext: OpaquePointer, into frame: VideoFrame) {
    var framebuffer = mpv_opengl_fbo(fbo: Int32(frame.renderFramebuffer), w: Int32(frame.width),
                                     h: Int32(frame.height), internal_format: Int32(VideoFramePool.renderInternalFormat))
    var flip: CInt = 0
    var depth: CInt = 16
    withUnsafeMutablePointer(to: &framebuffer) { framebuffer in
      withUnsafeMutablePointer(to: &flip) { flip in
        withUnsafeMutablePointer(to: &depth) { depth in
          var params: [mpv_render_param] = [
            mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: .init(framebuffer)),
            mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: .init(flip)),
            mpv_render_param(type: MPV_RENDER_PARAM_DEPTH, data: .init(depth)),
            mpv_render_param()
          ]
          mpv_render_context_render(renderContext, &params)
        }
      }
    }
  }

  private func present(_ pixelBuffer: CVPixelBuffer) {
    guard let sampleBuffer = ViewLayer.displayImmediatelySampleBuffer(pixelBuffer) else { return }
    if #available(macOS 14.0, *) {
      if sampleBufferRenderer.status == .failed { sampleBufferRenderer.flush() }
      sampleBufferRenderer.enqueue(sampleBuffer)
    } else {
      if status == .failed { flush() }
      enqueue(sampleBuffer)
    }
  }

  private static func displayImmediatelySampleBuffer(_ pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
    var formatDescription: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer,
                                                 formatDescriptionOut: &formatDescription)
    guard let formatDescription else { return nil }
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sampleBuffer: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer,
                                             formatDescription: formatDescription, sampleTiming: &timing,
                                             sampleBufferOut: &sampleBuffer)
    guard let sampleBuffer,
          let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [NSMutableDictionary],
          let sampleAttachments = attachments.first else { return nil }
    sampleAttachments[kCMSampleAttachmentKey_DisplayImmediately] = true
    return sampleBuffer
  }

  // MARK: - Snapshot

  private let snapshotLock = Lock()
  private var pendingSnapshotHandler: ((NSImage?) -> Void)?
  private lazy var snapshotContext = CIContext()

  /// Capture the next rendered frame as an `NSImage`. Forces a redraw so this works while paused.
  func captureSnapshot() async -> NSImage? {
    await withCheckedContinuation { continuation in
      // Drop any previous in-flight request — only the latest caller wins.
      let previous = snapshotLock.withLock { () -> ((NSImage?) -> Void)? in
        let previous = pendingSnapshotHandler
        pendingSnapshotHandler = { image in
          continuation.resume(returning: image)
        }
        return previous
      }
      previous?(nil)
      update(force: true)
    }
  }

  private func deliverPendingSnapshot(of pixelBuffer: CVPixelBuffer) {
    let handler = snapshotLock.withLock { () -> ((NSImage?) -> Void)? in
      let handler = pendingSnapshotHandler
      pendingSnapshotHandler = nil
      return handler
    }
    guard let handler else { return }
    let image = CIImage(cvPixelBuffer: pixelBuffer)
    let cgImage = snapshotContext.createCGImage(image, from: image.extent, format: .RGBA8,
                                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    handler(cgImage.map { NSImage(cgImage: $0, size: image.extent.size) })
  }

  // MARK: - Core OpenGL Context and Pixel Format

  private static func createPixelFormat(_ player: PlayerCore) -> CGLPixelFormatObj {
    var pix: CGLPixelFormatObj?
    var err: CGLError = CGLError(rawValue: 0)
    let swRender: CocoaCbSwRenderer = player.mpv.getEnum(MPVOption.GPURendererOptions.cocoaCbSwRenderer)

    if swRender != .yes {
      (pix, err) = ViewLayer.findPixelFormat(player)
    }

    if (err != kCGLNoError || pix == nil) && swRender != .no {
      (pix, err) = ViewLayer.findPixelFormat(player, software: true)
    }

    guard let pixelFormat = pix, err == kCGLNoError else {
      Logger.fatal("Cannot create OpenGL pixel format!")
    }

    return pixelFormat
  }

  private static func findPixelFormat(_ player: PlayerCore, software: Bool = false) -> (CGLPixelFormatObj?, CGLError) {
    let subsystem = Logger.makeSubsystem("layer\(player.playerNumber)", ["square.2.layers.3d.bottom.filled"])
    var pix: CGLPixelFormatObj?
    var err: CGLError = CGLError(rawValue: 0)
    var npix: GLint = 0

    for ver in glVersions {
      var glBase = software ? glFormatSoftwareBase : glFormatBase
      glBase.insert(CGLPixelFormatAttribute(ver.rawValue), at: 1)

      var glFormat = [glBase]
      if player.mpv.getFlag(MPVOption.GPURendererOptions.cocoaCb10bitContext) {
        glFormat += [glFormat10Bit]
      }
      glFormat += glFormatOptional

      if !Preference.bool(for: .forceDedicatedGPU) {
        glFormat += [glFormatAutoGPU]
      }

      for index in stride(from: glFormat.count-1, through: 0, by: -1) {
        let format = glFormat.flatMap { $0 } + [_CGLPixelFormatAttribute(rawValue: 0)]
        err = CGLChoosePixelFormat(format, &pix, &npix)

        if err == kCGLBadAttribute || err == kCGLBadPixelFormat || pix == nil {
          glFormat.remove(at: index)
        } else {
          let attArray = format.map({ (value: _CGLPixelFormatAttribute) -> String in
            return attributeLookUp[value.rawValue] ?? String(value.rawValue)
          })

          Logger.log("Created CGL pixel format with attributes: " +
                     "\(attArray.joined(separator: ", "))", subsystem: subsystem)
          return (pix, err)
        }
      }
    }

    let errS = String(cString: CGLErrorString(err))
    Logger.log("Couldn't create a " + "\(software ? "software" : "hardware accelerated") " +
               "CGL pixel format: \(errS) (\(err.rawValue))", subsystem: subsystem)
    let swRenderer: CocoaCbSwRenderer = player.mpv.getEnum(MPVOption.GPURendererOptions.cocoaCbSwRenderer)
    if software == false && swRenderer == .auto {
      Logger.log("Falling back to software renderer", subsystem: subsystem)
    }

    return (pix, err)
  }

  private static func createContext(_ pixelFormat: CGLPixelFormatObj) -> CGLContextObj {
    var ctx: CGLContextObj?
    CGLCreateContext(pixelFormat, nil, &ctx)

    guard let ctx else {
      Logger.fatal("Cannot create OpenGL context!")
    }

    // Enable multi-threaded GL engine.
    CGLEnable(ctx, kCGLCEMPEngine)

    CGLSetCurrentContext(ctx)
    return ctx
  }
}
