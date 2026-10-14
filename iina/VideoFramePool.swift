//
//  VideoFramePool.swift
//  iina
//

import CoreVideo
import IOSurface
import OpenGL.GL3

struct VideoFrame {
  let pixelBuffer: CVPixelBuffer
  let renderFramebuffer: GLuint
  let width: Int
  let height: Int
  fileprivate let planeFramebuffer: GLuint?
}

/// ```swift
/// let pool = VideoFramePool(width: 1920, height: 1080, encoding: .ycbcr, context: cglContext)!
/// let frame = pool.nextFrame()!
/// renderMPV(into: frame.renderFramebuffer)
/// pool.finish(frame, matrix: colorimetry.ycbcrMatrix)
/// ```
/// - Important: Use only with `context` locked and current.
final class VideoFramePool {
  static let renderInternalFormat = GLenum(GL_RGBA16F)

  let width: Int
  let height: Int
  let encoding: FrameEncoding
  private let context: CGLContextObj
  private let pixelBufferPool: CVPixelBufferPool
  private let encoder: YCbCrEncoder?
  private let renderTarget: (framebuffer: GLuint, texture: GLuint)?
  private var framebufferBySurfaceID: [IOSurfaceID: (framebuffer: GLuint, textures: [GLuint])] = [:]

  init?(width: Int, height: Int, encoding: FrameEncoding, encoder: YCbCrEncoder?, context: CGLContextObj) {
    let pixelFormat = encoding == .ycbcr
      ? kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_64RGBAHalf
    let poolAttributes: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: 3]
    let pixelBufferAttributes: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: pixelFormat,
      kCVPixelBufferWidthKey: width,
      kCVPixelBufferHeightKey: height,
      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
      kCVPixelBufferOpenGLCompatibilityKey: true,
    ]
    var pool: CVPixelBufferPool?
    CVPixelBufferPoolCreate(nil, poolAttributes as CFDictionary, pixelBufferAttributes as CFDictionary, &pool)
    guard let pool else { return nil }
    if encoding == .ycbcr {
      guard encoder != nil, let target = VideoFramePool.makeRenderTarget(width: width, height: height) else { return nil }
      renderTarget = target
    } else {
      renderTarget = nil
    }
    self.width = width
    self.height = height
    self.encoding = encoding
    self.encoder = encoder
    self.context = context
    pixelBufferPool = pool
  }

  func nextFrame() -> VideoFrame? {
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &pixelBuffer)
    guard let pixelBuffer, let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else {
      return nil
    }
    CVBufferRemoveAllAttachments(pixelBuffer)
    let surfaceID = IOSurfaceGetID(surface)
    if framebufferBySurfaceID[surfaceID] == nil {
      guard let created = makeFramebuffer(over: surface) else { return nil }
      framebufferBySurfaceID[surfaceID] = created
    }
    let surfaceFramebuffer = framebufferBySurfaceID[surfaceID]!.framebuffer
    switch encoding {
    case .ycbcr:
      return VideoFrame(pixelBuffer: pixelBuffer, renderFramebuffer: renderTarget!.framebuffer, width: width,
                        height: height, planeFramebuffer: surfaceFramebuffer)
    case .rgb:
      return VideoFrame(pixelBuffer: pixelBuffer, renderFramebuffer: surfaceFramebuffer, width: width,
                        height: height, planeFramebuffer: nil)
    }
  }

  func finish(_ frame: VideoFrame, matrix: YCbCrMatrix) {
    if let planeFramebuffer = frame.planeFramebuffer, let renderTarget, let encoder {
      encoder.encode(texture: renderTarget.texture, into: planeFramebuffer, width: width, height: height,
                     matrix: matrix)
    }
    glFinish()
  }

  func deleteFramebuffers() {
    for (framebuffer, textures) in framebufferBySurfaceID.values {
      VideoFramePool.delete(framebuffer: framebuffer, textures: textures)
    }
    framebufferBySurfaceID.removeAll()
    if let renderTarget {
      VideoFramePool.delete(framebuffer: renderTarget.framebuffer, textures: [renderTarget.texture])
    }
  }

  private static func delete(framebuffer: GLuint, textures: [GLuint]) {
    var framebuffer = framebuffer
    var textures = textures
    glDeleteFramebuffers(1, &framebuffer)
    glDeleteTextures(GLsizei(textures.count), &textures)
  }

  private static func makeRenderTarget(width: Int, height: Int) -> (framebuffer: GLuint, texture: GLuint)? {
    var texture: GLuint = 0
    glGenTextures(1, &texture)
    glBindTexture(GLenum(GL_TEXTURE_2D), texture)
    glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_NEAREST)
    glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_NEAREST)
    glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_RGBA16F, GLsizei(width), GLsizei(height), 0, GLenum(GL_RGBA),
                 GLenum(GL_HALF_FLOAT), nil)
    glBindTexture(GLenum(GL_TEXTURE_2D), 0)
    return attachedFramebuffer(textures: [texture], target: GLenum(GL_TEXTURE_2D))
  }

  private func makeFramebuffer(over surface: IOSurfaceRef) -> (framebuffer: GLuint, textures: [GLuint])? {
    let planes: [(internalFormat: Int32, format: Int32, type: Int32)] = encoding == .ycbcr
      ? [(GL_R16, GL_RED, GL_UNSIGNED_SHORT), (GL_RG16, GL_RG, GL_UNSIGNED_SHORT)]
      : [(GL_RGBA16F, GL_RGBA, GL_HALF_FLOAT)]
    var textures = [GLuint](repeating: 0, count: planes.count)
    glGenTextures(GLsizei(textures.count), &textures)
    for (plane, layout) in planes.enumerated() {
      glBindTexture(GLenum(GL_TEXTURE_RECTANGLE), textures[plane])
      let bound = CGLTexImageIOSurface2D(context, GLenum(GL_TEXTURE_RECTANGLE), GLenum(layout.internalFormat),
                                         GLsizei(width), GLsizei(height), GLenum(layout.format), GLenum(layout.type),
                                         surface, GLuint(plane))
      guard bound == kCGLNoError else {
        Logger.log("Cannot bind IOSurface plane \(plane): CGL error \(bound.rawValue)", level: .error)
        glBindTexture(GLenum(GL_TEXTURE_RECTANGLE), 0)
        glDeleteTextures(GLsizei(textures.count), &textures)
        return nil
      }
    }
    glBindTexture(GLenum(GL_TEXTURE_RECTANGLE), 0)
    guard let attached = VideoFramePool.attachedFramebuffer(textures: textures, target: GLenum(GL_TEXTURE_RECTANGLE))
    else { return nil }
    return (attached.framebuffer, textures)
  }

  private static func attachedFramebuffer(textures: [GLuint], target: GLenum) -> (framebuffer: GLuint, texture: GLuint)? {
    var framebuffer: GLuint = 0
    glGenFramebuffers(1, &framebuffer)
    glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
    for (index, texture) in textures.enumerated() {
      glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0) + GLenum(index), target, texture, 0)
    }
    let status = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
    glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
    guard status == GLenum(GL_FRAMEBUFFER_COMPLETE) else {
      Logger.log("Incomplete framebuffer: status \(status)", level: .error)
      var textures = textures
      glDeleteFramebuffers(1, &framebuffer)
      glDeleteTextures(GLsizei(textures.count), &textures)
      return nil
    }
    return (framebuffer, textures[0])
  }
}

/// Writes `kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange` planes from an RGB texture.
///
/// - Important: Requires an OpenGL 3.2 core profile context, locked and current.
final class YCbCrEncoder {
  private let program: GLuint
  private let vertexArray: GLuint
  private let sourceLocation: GLint
  private let lumaCoefficientsLocation: GLint
  private let chromaScaleLocation: GLint

  private static let vertexShader = """
    #version 150
    void main() {
      vec2 corner = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
      gl_Position = vec4(corner * 2.0 - 1.0, 0.0, 1.0);
    }
    """

  private static let fragmentShader = """
    #version 150
    uniform sampler2D source;
    uniform vec3 lumaCoefficients;
    uniform vec2 chromaScale;
    out vec4 luma;
    out vec4 chroma;
    float leftAligned(float code) {
      return clamp(floor(code + 0.5), 4.0, 1019.0) * 64.0 / 65535.0;
    }
    void main() {
      vec3 rgb = texelFetch(source, ivec2(gl_FragCoord.xy), 0).rgb;
      float y = dot(rgb, lumaCoefficients);
      vec2 cbcr = vec2(rgb.b - y, rgb.r - y) * chromaScale;
      luma = vec4(leftAligned(64.0 + 876.0 * y), 0.0, 0.0, 1.0);
      chroma = vec4(leftAligned(512.0 + 896.0 * cbcr.x), leftAligned(512.0 + 896.0 * cbcr.y), 0.0, 1.0);
    }
    """

  init?() {
    guard let vertex = YCbCrEncoder.compile(YCbCrEncoder.vertexShader, type: GLenum(GL_VERTEX_SHADER)),
          let fragment = YCbCrEncoder.compile(YCbCrEncoder.fragmentShader, type: GLenum(GL_FRAGMENT_SHADER)) else {
      return nil
    }
    let program = glCreateProgram()
    glAttachShader(program, vertex)
    glAttachShader(program, fragment)
    glBindFragDataLocation(program, 0, "luma")
    glBindFragDataLocation(program, 1, "chroma")
    glLinkProgram(program)
    glDeleteShader(vertex)
    glDeleteShader(fragment)
    var linked: GLint = 0
    glGetProgramiv(program, GLenum(GL_LINK_STATUS), &linked)
    guard linked == GL_TRUE else {
      Logger.log("Cannot link Y'CbCr encoder: \(YCbCrEncoder.programLog(program))", level: .error)
      glDeleteProgram(program)
      return nil
    }
    var vertexArray: GLuint = 0
    glGenVertexArrays(1, &vertexArray)
    self.program = program
    self.vertexArray = vertexArray
    sourceLocation = glGetUniformLocation(program, "source")
    lumaCoefficientsLocation = glGetUniformLocation(program, "lumaCoefficients")
    chromaScaleLocation = glGetUniformLocation(program, "chromaScale")
  }

  func encode(texture: GLuint, into framebuffer: GLuint, width: Int, height: Int, matrix: YCbCrMatrix) {
    let red = Float(matrix.redCoefficient)
    let blue = Float(matrix.blueCoefficient)
    var drawBuffers = [GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_COLOR_ATTACHMENT1)]
    glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
    glDrawBuffers(2, &drawBuffers)
    glViewport(0, 0, GLsizei(width), GLsizei(height))
    glDisable(GLenum(GL_BLEND))
    glDisable(GLenum(GL_SCISSOR_TEST))
    glUseProgram(program)
    glActiveTexture(GLenum(GL_TEXTURE0))
    glBindTexture(GLenum(GL_TEXTURE_2D), texture)
    glUniform1i(sourceLocation, 0)
    glUniform3f(lumaCoefficientsLocation, red, 1 - red - blue, blue)
    glUniform2f(chromaScaleLocation, 1 / (2 * (1 - blue)), 1 / (2 * (1 - red)))
    glBindVertexArray(vertexArray)
    glDrawArrays(GLenum(GL_TRIANGLES), 0, 3)
    glBindVertexArray(0)
    glBindTexture(GLenum(GL_TEXTURE_2D), 0)
    glUseProgram(0)
    glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
  }

  private static func compile(_ source: String, type: GLenum) -> GLuint? {
    let shader = glCreateShader(type)
    source.withCString { text in
      var pointer: UnsafePointer<GLchar>? = text
      glShaderSource(shader, 1, &pointer, nil)
    }
    glCompileShader(shader)
    var compiled: GLint = 0
    glGetShaderiv(shader, GLenum(GL_COMPILE_STATUS), &compiled)
    guard compiled == GL_TRUE else {
      var log = [GLchar](repeating: 0, count: 2048)
      glGetShaderInfoLog(shader, GLsizei(log.count), nil, &log)
      Logger.log("Cannot compile Y'CbCr encoder: \(String(cString: log))", level: .error)
      glDeleteShader(shader)
      return nil
    }
    return shader
  }

  private static func programLog(_ program: GLuint) -> String {
    var log = [GLchar](repeating: 0, count: 2048)
    glGetProgramInfoLog(program, GLsizei(log.count), nil, &log)
    return String(cString: log)
  }
}
