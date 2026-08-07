import CoreML
import Foundation

/// Everything Wyoming's `info` response needs to describe the model this
/// server is running. Defaults match the German primeline fine-tune this
/// project was built around, but every field is a CLI flag — point this at
/// any FluidAudio-compatible v3 fine-tune (a different language's) without
/// forking.
struct ModelInfo {
    var name = "parakeet-primeline-de"
    var version = "2_95_WER"
    /// BCP-47 language code advertised in Wyoming's `info`/`transcript`
    /// events — this is what makes Home Assistant offer the entity on the
    /// matching-language Assist pipeline.
    var language = "de"
    var attributionName = "primeline / NVIDIA / FluidInference"
    var attributionURL = "https://huggingface.co/primeline/parakeet-primeline"
    var modelDescription = "German Parakeet TDT 0.6B v3 fine-tune, running on the Apple Neural Engine via FluidAudio"
    var programDescription = "German Parakeet TDT 0.6B v3 (primeline fine-tune) on ANE"
}

struct ServerArgs {
    var modelsDir: URL?
    var port: UInt16 = 10300
    var computeUnits: MLComputeUnits?
    var modelInfo = ModelInfo()
}

func parseComputeUnits(_ s: String) -> MLComputeUnits? {
    switch s.lowercased() {
    case "ane", "cpuandneuralengine", "neural-engine": return .cpuAndNeuralEngine
    case "gpu", "cpuandgpu": return .cpuAndGPU
    case "cpu", "cpuonly": return .cpuOnly
    case "all": return .all
    default:
        fputs("Unknown --compute-units '\(s)'. Use ane, gpu, cpu, or all.\n", stderr)
        exit(1)
    }
}

func parseArgs() -> ServerArgs {
    var result = ServerArgs()
    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--models-dir":
            if i + 1 < args.count { result.modelsDir = URL(fileURLWithPath: args[i + 1]); i += 1 }
        case "--port":
            if i + 1 < args.count, let p = UInt16(args[i + 1]) { result.port = p; i += 1 }
        case "--compute-units":
            if i + 1 < args.count { result.computeUnits = parseComputeUnits(args[i + 1]); i += 1 }
        case "--model-name":
            if i + 1 < args.count { result.modelInfo.name = args[i + 1]; i += 1 }
        case "--model-version":
            if i + 1 < args.count { result.modelInfo.version = args[i + 1]; i += 1 }
        case "--language":
            if i + 1 < args.count { result.modelInfo.language = args[i + 1]; i += 1 }
        case "--attribution-name":
            if i + 1 < args.count { result.modelInfo.attributionName = args[i + 1]; i += 1 }
        case "--attribution-url":
            if i + 1 < args.count { result.modelInfo.attributionURL = args[i + 1]; i += 1 }
        case "--model-description":
            if i + 1 < args.count { result.modelInfo.modelDescription = args[i + 1]; i += 1 }
        case "--program-description":
            if i + 1 < args.count { result.modelInfo.programDescription = args[i + 1]; i += 1 }
        default:
            break
        }
        i += 1
    }
    return result
}

/// Serializes connection-ID assignment across concurrent `newConnectionHandler`
/// invocations without relying on the (unenforceable-by-the-compiler) fact
/// that NWListener happens to call it serially on the queue we pass in.
actor ConnectionIDGenerator {
    private var next = 0
    func nextID() -> Int {
        next += 1
        return next
    }
}

/// Owns the one persistent strong reference to each live `Connection`.
///
/// Without this, nothing keeps a `Connection` actor alive: every reference
/// to it from NWConnection's own completion handlers is `[weak self]] (so a
/// hung/slow handler can't leak the connection forever), and the single
/// `Task { await connection.start() }` that constructs it releases its
/// strong capture as soon as `start()` returns — which happens almost
/// immediately, since `start()` just registers handlers and returns. The
/// result: the actor gets deallocated microseconds after the connection is
/// accepted, and every subsequent NWConnection callback's `guard let self
/// else { return }` silently no-ops with no log line and no error, which
/// looks exactly like a hung connection.
actor ConnectionRegistry {
    private var connections: [Int: Connection] = [:]

    func add(_ connection: Connection, id: Int) {
        connections[id] = connection
    }

    func remove(id: Int) {
        connections.removeValue(forKey: id)
    }
}
