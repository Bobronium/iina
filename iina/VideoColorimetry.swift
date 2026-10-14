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
/// CVBufferSetAttachments(renderedFrame, output.pixelBufferAttachments as CFDictionary, .shouldPropagate)
/// ```
struct VideoColorimetry: Equatable {
  let primaries: String
  let transfer: String
  var signalPeakNits: Double? = nil
  var masteringDisplay: MasteringDisplay? = nil
  var contentLightLevel: ContentLightLevel? = nil

  static let standardDynamicRange = VideoColorimetry(primaries: "bt.709", transfer: "bt.1886")

  var isHDR: Bool { VideoColorimetry.highDynamicRangeTransfers.contains(transfer) }

  /// mpv `target-peak` that keeps rendering in this colorimetry an identity: the HLG OOTF is undone with the same
  /// display peak it was applied with.
  var targetPeak: String {
    guard transfer == "hlg", let signalPeakNits else { return "auto" }
    return String(Int(signalPeakNits.rounded()).clamped(to: 10...10000))
  }

  var presentable: VideoColorimetry {
    let presentablePrimaries = VideoColorimetry.primariesByName[primaries] == nil ? "bt.2020" : primaries
    let fallbackTransfer = isHDR ? "pq" : "bt.1886"
    let presentableTransfer = VideoColorimetry.transferByName[transfer] == nil ? fallbackTransfer : transfer
    return VideoColorimetry(primaries: presentablePrimaries, transfer: presentableTransfer,
                            signalPeakNits: signalPeakNits, masteringDisplay: masteringDisplay,
                            contentLightLevel: contentLightLevel)
  }

  var pixelBufferAttachments: [CFString: Any] {
    var attachments = coreVideoTags
    if !isHDR, let colorSpace = VideoColorimetry.decodedVideoColorSpace(taggedWith: attachments) {
      attachments[kCVImageBufferCGColorSpaceKey] = colorSpace
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
                            signalPeakNits: signalPeak.map { $0 * MPVController.referenceWhiteNits },
                            masteringDisplay: masteringDisplay(containerPrimaries: primaries),
                            contentLightLevel: contentLightLevel())
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
