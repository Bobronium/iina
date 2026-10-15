//
//  VideoColorimetry.swift
//  iina
//

import CoreVideo

/// Color encoding of rendered video frames, in mpv's names, and the CoreVideo tags that let macOS display them.
///
/// ```swift
/// let output = mpv.videoColorimetry()!.presentable
/// mpv.setString(MPVOption.GPURendererOptions.targetPrim, output.primaries)
/// mpv.setString(MPVOption.GPURendererOptions.targetTrc, output.transfer)
/// CVBufferSetAttachments(renderedFrame, output.pixelBufferAttachments(for: .ycbcr) as CFDictionary, .shouldPropagate)
/// ```
struct VideoColorimetry: Equatable {
  let primaries: String
  let transfer: String
  var matrix = "auto"
  var signalPeakNits: Double? = nil
  var masteringDisplay: MasteringDisplay? = nil
  var contentLightLevel: ContentLightLevel? = nil
  var dolbyVisionProfile: Int? = nil

  static let standardDynamicRange = VideoColorimetry(primaries: "bt.709", transfer: "bt.1886", matrix: "bt.709")

  var isHDR: Bool { VideoColorimetry.highDynamicRangeTransfers.contains(transfer) }

  var targetPeak: String {
    guard transfer == "hlg", let signalPeakNits else { return "auto" }
    return String(Int(signalPeakNits.rounded()).clamped(to: 10...10000))
  }

  var presentable: VideoColorimetry {
    let presentablePrimaries = VideoColorimetry.primariesByName[primaries] == nil ? "bt.2020" : primaries
    let fallbackTransfer = isHDR ? "pq" : "bt.1886"
    let presentableTransfer = VideoColorimetry.transferByName[transfer] == nil ? fallbackTransfer : transfer
    let presentableMatrix = YCbCrMatrix.byName[matrix] == nil
      ? (presentablePrimaries == "bt.2020" ? "bt.2020-ncl" : "bt.709") : matrix
    return VideoColorimetry(primaries: presentablePrimaries, transfer: presentableTransfer, matrix: presentableMatrix,
                            signalPeakNits: signalPeakNits, masteringDisplay: masteringDisplay,
                            contentLightLevel: contentLightLevel, dolbyVisionProfile: dolbyVisionProfile)
  }

  var ycbcrMatrix: YCbCrMatrix {
    YCbCrMatrix.byName[presentable.matrix] ?? .bt709
  }

  /// Dolby Vision `bl_signal_compatibility_id`.
  var dolbyVisionCompatibilityID: Int? {
    switch (dolbyVisionProfile, transfer) {
    case (5, _): return 0
    case (7, _): return 6
    case (8, "pq"): return 1
    case (8, "hlg"): return 4
    case (8, _): return 2
    default: return nil
    }
  }

  func pixelBufferAttachments(for encoding: FrameEncoding) -> [CFString: Any] {
    var attachments = coreVideoTags
    switch encoding {
    case .ycbcr:
      attachments[kCVImageBufferYCbCrMatrixKey] = ycbcrMatrix.coreVideoName
      attachments[kCVImageBufferCGColorSpaceKey] = VideoColorimetry.decodedVideoColorSpace(taggedWith: attachments)
    case .rgb where !isHDR:
      attachments[kCVImageBufferCGColorSpaceKey] = VideoColorimetry.decodedVideoColorSpace(taggedWith: attachments)
    case .rgb:
      break
    }
    return attachments
  }

  private var coreVideoTags: [CFString: Any] {
    var tags: [CFString: Any] = [:]
    tags[kCVImageBufferColorPrimariesKey] = VideoColorimetry.primariesByName[primaries]
    switch VideoColorimetry.transferByName[transfer] {
    case .named(let function):
      tags[kCVImageBufferTransferFunctionKey] = function
    case .gamma(let level):
      tags[kCVImageBufferTransferFunctionKey] = kCVImageBufferTransferFunction_UseGamma
      tags[kCVImageBufferGammaLevelKey] = level
    case nil:
      break
    }
    tags[kCVImageBufferMasteringDisplayColorVolumeKey] = masteringDisplay?.seiPayload
    tags[kCVImageBufferContentLightLevelInfoKey] = contentLightLevel?.seiPayload
    return tags
  }

  private static func decodedVideoColorSpace(taggedWith tags: [CFString: Any]) -> CGColorSpace? {
    CVImageBufferCreateColorSpaceFromAttachments(tags as CFDictionary)?.takeRetainedValue()
  }

  private enum CoreTransfer {
    case named(CFString)
    case gamma(Double)
  }

  private static let highDynamicRangeTransfers: Set = ["pq", "hlg", "v-log", "s-log1", "s-log2"]

  private static let primariesByName: [String: CFString] = [
    "bt.709": kCVImageBufferColorPrimaries_ITU_R_709_2,
    "bt.601-525": kCVImageBufferColorPrimaries_SMPTE_C,
    "bt.601-625": kCVImageBufferColorPrimaries_EBU_3213,
    "bt.2020": kCVImageBufferColorPrimaries_ITU_R_2020,
    "dci-p3": kCVImageBufferColorPrimaries_DCI_P3,
    "display-p3": kCVImageBufferColorPrimaries_P3_D65,
  ]

  private static let transferByName: [String: CoreTransfer] = [
    "bt.1886": .named(kCVImageBufferTransferFunction_ITU_R_709_2),
    "srgb": .named(kCVImageBufferTransferFunction_sRGB),
    "linear": .named(kCVImageBufferTransferFunction_Linear),
    "st428": .named(kCVImageBufferTransferFunction_SMPTE_ST_428_1),
    "pq": .named(kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ),
    "hlg": .named(kCVImageBufferTransferFunction_ITU_R_2100_HLG),
    "gamma1.8": .gamma(1.8),
    "gamma2.0": .gamma(2.0),
    "gamma2.2": .gamma(2.2),
    "gamma2.4": .gamma(2.4),
    "gamma2.6": .gamma(2.6),
    "gamma2.8": .gamma(2.8),
  ]
}

enum FrameEncoding {
  case ycbcr
  case rgb
}

/// Y'CbCr encoding coefficients, ITU-T H.273.
struct YCbCrMatrix: Equatable {
  let redCoefficient: Double
  let blueCoefficient: Double
  let coreVideoName: CFString

  static let bt709 = YCbCrMatrix(redCoefficient: 0.2126, blueCoefficient: 0.0722,
                                 coreVideoName: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
  static let bt601 = YCbCrMatrix(redCoefficient: 0.299, blueCoefficient: 0.114,
                                 coreVideoName: kCVImageBufferYCbCrMatrix_ITU_R_601_4)
  static let bt2020 = YCbCrMatrix(redCoefficient: 0.2627, blueCoefficient: 0.0593,
                                  coreVideoName: kCVImageBufferYCbCrMatrix_ITU_R_2020)
  static let smpte240 = YCbCrMatrix(redCoefficient: 0.212, blueCoefficient: 0.087,
                                    coreVideoName: kCVImageBufferYCbCrMatrix_SMPTE_240M_1995)

  static let byName: [String: YCbCrMatrix] = [
    "bt.709": .bt709,
    "bt.601": .bt601,
    "bt.2020-ncl": .bt2020,
    "bt.2020-cl": .bt2020,
    "dolbyvision": .bt2020,
    "smpte-240m": .smpte240,
  ]
}

struct Chromaticity: Equatable {
  let x: Double
  let y: Double
}

/// SMPTE ST 2086 mastering display color volume.
struct MasteringDisplay: Equatable {
  let red: Chromaticity
  let green: Chromaticity
  let blue: Chromaticity
  let white: Chromaticity
  let minimumLuminanceNits: Double
  let maximumLuminanceNits: Double

  /// ISO/IEC 23008-2 D.2.28 mastering display colour volume SEI payload.
  var seiPayload: Data {
    let chromaticityUnitsPerCoordinate = 50_000.0
    let luminanceUnitsPerNit = 10_000.0
    let coordinates = [green, blue, red, white].flatMap { [$0.x, $0.y] }
      .map { UInt16(clamping: Int(($0 * chromaticityUnitsPerCoordinate).rounded())) }
    let luminances = [maximumLuminanceNits, minimumLuminanceNits]
      .map { UInt32(clamping: Int(($0 * luminanceUnitsPerNit).rounded())) }
    return Data(bigEndian: coordinates) + Data(bigEndian: luminances)
  }
}

/// CTA-861.3 content light level.
struct ContentLightLevel: Equatable {
  let maximumContentLightLevelNits: Double
  let maximumFrameAverageLightLevelNits: Double

  /// ISO/IEC 23008-2 D.2.35 content light level information SEI payload.
  var seiPayload: Data {
    Data(bigEndian: [maximumContentLightLevelNits, maximumFrameAverageLightLevelNits]
      .map { UInt16(clamping: Int($0.rounded())) })
  }
}

private extension Data {
  init<Integer: FixedWidthInteger>(bigEndian integers: [Integer]) {
    self.init()
    for integer in integers {
      Swift.withUnsafeBytes(of: integer.bigEndian) { append(contentsOf: $0) }
    }
  }
}

extension MPVController {
  private static let referenceWhiteNits = 203.0

  func videoColorimetry() -> VideoColorimetry? {
    guard let primaries = getString(MPVProperty.videoParamsPrimaries),
          let transfer = getString(MPVProperty.videoParamsGamma) else { return nil }
    let signalPeak = optionalDouble(MPVProperty.videoParamsSigPeak).flatMap { $0 > 0 ? $0 : nil }
    return VideoColorimetry(primaries: primaries, transfer: transfer,
                            matrix: getString(MPVProperty.videoParamsColormatrix) ?? "auto",
                            signalPeakNits: signalPeak.map { $0 * MPVController.referenceWhiteNits },
                            masteringDisplay: masteringDisplay(containerPrimaries: primaries),
                            contentLightLevel: contentLightLevel(),
                            dolbyVisionProfile: getString(MPVProperty.currentTracksVideoDolbyVisionProfile).flatMap(Int.init))
  }

  /// - Important: Call on the rendering thread right after `mpv_render_context_render`.
  func renderedFrameDolbyVisionRPU() -> Data? {
    guard let mpvRenderContext else { return nil }
    var rpu = mpv_byte_array()
    let status = withUnsafeMutablePointer(to: &rpu) { pointer in
      mpv_render_context_get_info(mpvRenderContext, mpv_render_param(type: MPV_RENDER_PARAM_DOVI_RPU, data: pointer))
    }
    guard status >= 0, let bytes = rpu.data, rpu.size > 0 else { return nil }
    defer { mpv_free(bytes) }
    return Data(bytes: bytes, count: rpu.size)
  }

  private func optionalDouble(_ property: String) -> Double? {
    getString(property).flatMap(Double.init)
  }

  private func chromaticity(x: String, y: String) -> Chromaticity? {
    guard let x = optionalDouble(x), let y = optionalDouble(y) else { return nil }
    return Chromaticity(x: x, y: y)
  }

  private func masteringDisplay(containerPrimaries: String) -> MasteringDisplay? {
    guard let maximumLuminance = optionalDouble(MPVProperty.videoParamsMaxLuma),
          let minimumLuminance = optionalDouble(MPVProperty.videoParamsMinLuma) else { return nil }
    let container = PrimaryChromaticities.byName[containerPrimaries]
    guard let red = chromaticity(x: MPVProperty.videoParamsPrimRedX, y: MPVProperty.videoParamsPrimRedY) ?? container?.red,
          let green = chromaticity(x: MPVProperty.videoParamsPrimGreenX, y: MPVProperty.videoParamsPrimGreenY) ?? container?.green,
          let blue = chromaticity(x: MPVProperty.videoParamsPrimBlueX, y: MPVProperty.videoParamsPrimBlueY) ?? container?.blue,
          let white = chromaticity(x: MPVProperty.videoParamsPrimWhiteX, y: MPVProperty.videoParamsPrimWhiteY) ?? container?.white
    else { return nil }
    return MasteringDisplay(red: red, green: green, blue: blue, white: white,
                            minimumLuminanceNits: minimumLuminance, maximumLuminanceNits: maximumLuminance)
  }

  private func contentLightLevel() -> ContentLightLevel? {
    guard let maximum = optionalDouble(MPVProperty.videoParamsMaxCll),
          let frameAverage = optionalDouble(MPVProperty.videoParamsMaxFall) else { return nil }
    return ContentLightLevel(maximumContentLightLevelNits: maximum, maximumFrameAverageLightLevelNits: frameAverage)
  }
}

private struct PrimaryChromaticities {
  let red: Chromaticity
  let green: Chromaticity
  let blue: Chromaticity
  let white: Chromaticity

  private static let d65 = Chromaticity(x: 0.3127, y: 0.3290)

  static let byName: [String: PrimaryChromaticities] = [
    "bt.709": PrimaryChromaticities(red: Chromaticity(x: 0.640, y: 0.330), green: Chromaticity(x: 0.300, y: 0.600),
                                    blue: Chromaticity(x: 0.150, y: 0.060), white: d65),
    "bt.2020": PrimaryChromaticities(red: Chromaticity(x: 0.708, y: 0.292), green: Chromaticity(x: 0.170, y: 0.797),
                                     blue: Chromaticity(x: 0.131, y: 0.046), white: d65),
    "display-p3": PrimaryChromaticities(red: Chromaticity(x: 0.680, y: 0.320), green: Chromaticity(x: 0.265, y: 0.690),
                                        blue: Chromaticity(x: 0.150, y: 0.060), white: d65),
  ]
}
