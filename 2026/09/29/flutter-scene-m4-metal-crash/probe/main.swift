// Compiles each .metal file given on the command line into a render pipeline on
// the default device, to find which shader crashes MTLCompilerService.
import Foundation
import Metal

let device = MTLCreateSystemDefaultDevice()!
print("device: \(device.name)")

func dataTypeToFormat(_ t: MTLDataType) -> MTLVertexFormat? {
  switch t {
  case .float: return .float
  case .float2: return .float2
  case .float3: return .float3
  case .float4: return .float4
  case .int: return .int
  case .int2: return .int2
  case .int3: return .int3
  case .int4: return .int4
  case .uint: return .uint
  case .uint2: return .uint2
  case .uint3: return .uint3
  case .uint4: return .uint4
  case .half2: return .half2
  case .half4: return .half4
  default: return nil
  }
}

let trivialFragmentSrc = """
#include <metal_stdlib>
using namespace metal;
fragment half4 probe_fragment() { return half4(1.0h); }
"""

func matchingVertexSource(forFragment src: String) -> String? {
  // fragment <ret> <name>(<Struct> in [[stage_in]] ...
  let pattern = #"fragment\s+\S+\s+\w+\s*\(\s*(\w+)\s+\w+\s*\[\[stage_in\]\]"#
  guard let re = try? NSRegularExpression(pattern: pattern),
        let m = re.firstMatch(in: src, range: NSRange(src.startIndex..., in: src)),
        let r = Range(m.range(at: 1), in: src) else { return nil }
  let structName = String(src[r])
  let spattern = "struct \(structName)\\s*\\{([^}]*)\\};"
  guard let sre = try? NSRegularExpression(pattern: spattern),
        let sm = sre.firstMatch(in: src, range: NSRange(src.startIndex..., in: src)),
        let sr = Range(sm.range(at: 1), in: src) else { return nil }
  let body = String(src[sr])
  return """
  #include <metal_stdlib>
  using namespace metal;
  struct ProbeOut {\(body)
    float4 probe_position [[position]];
  };
  vertex ProbeOut probe_vertex() { ProbeOut o = {}; return o; }
  """
}

func makeLib(_ src: String) throws -> MTLLibrary {
  let o = MTLCompileOptions()
  let env = ProcessInfo.processInfo.environment
  if env["PROBE_MATH"] == "safe" { o.mathMode = .safe }
  if env["PROBE_MATH"] == "relaxed" { o.mathMode = .relaxed }
  if env["PROBE_OPT"] == "size" { o.optimizationLevel = .size }
  if env["PROBE_PRESERVE_INVARIANCE"] == "1" { o.preserveInvariance = true }
  return try device.makeLibrary(source: src, options: o)
}

func configureAttachments(_ d: MTLRenderPipelineDescriptor) {
  for i in 0..<4 { d.colorAttachments[i].pixelFormat = .rgba16Float }
  d.depthAttachmentPixelFormat = .depth32Float_stencil8
  d.stencilAttachmentPixelFormat = .depth32Float_stencil8
}

let trivialFragLib = try! makeLib(trivialFragmentSrc)

for path in CommandLine.arguments.dropFirst() {
  let name = (path as NSString).lastPathComponent
  let src = try! String(contentsOfFile: path, encoding: .utf8)
  FileHandle.standardOutput.write("\(name): ".data(using: .utf8)!)
  do {
    let lib = try makeLib(src)
    guard let fname = lib.functionNames.first, let fn = lib.makeFunction(name: fname) else {
      print("no function"); continue
    }
    let d = MTLRenderPipelineDescriptor()
    configureAttachments(d)
    if fn.functionType == .vertex {
      d.vertexFunction = fn
      d.fragmentFunction = trivialFragLib.makeFunction(name: "probe_fragment")
      if let attrs = fn.vertexAttributes, !attrs.isEmpty {
        let vd = MTLVertexDescriptor()
        var offset = 0
        for a in attrs where a.isActive {
          guard let f = dataTypeToFormat(a.attributeType) else { continue }
          vd.attributes[a.attributeIndex].format = f
          vd.attributes[a.attributeIndex].bufferIndex = 30
          vd.attributes[a.attributeIndex].offset = offset
          offset += 16
        }
        vd.layouts[30].stride = max(offset, 16)
        d.vertexDescriptor = vd
      }
    } else {
      d.fragmentFunction = fn
      if let vsrc = matchingVertexSource(forFragment: src) {
        d.vertexFunction = try makeLib(vsrc).makeFunction(name: "probe_vertex")
      } else {
        let vlib = try makeLib("""
          #include <metal_stdlib>
          using namespace metal;
          vertex float4 probe_vertex() { return float4(0.0); }
          """)
        d.vertexFunction = vlib.makeFunction(name: "probe_vertex")
      }
    }
    _ = try device.makeRenderPipelineState(descriptor: d)
    print("ok")
  } catch {
    let msg = "\(error)".replacingOccurrences(of: "\n", with: " ")
    print("ERROR \(msg.prefix(300))")
  }
}
