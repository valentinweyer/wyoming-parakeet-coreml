// WyomingParakeet: a thin Wyoming-protocol TCP server wrapping FluidAudio's
// CoreML/ANE inference of the primeline German Parakeet fine-tune, so Home
// Assistant's Assist pipeline can use it as a normal stt.* entity.
//
// Usage:
//   WyomingParakeet --models-dir <path/to/parakeet-tdt-0.6b-v3> \
//                    [--port 10300] [--compute-units ane|gpu|cpu|all]

import CoreML
import FluidAudio
import Foundation
import Network

@main
struct WyomingParakeetServer {
    static func main() async {
        // Hard invariant: never let FluidAudio delete our converted bundle
        // on a load failure and silently re-download the official English
        // v3. Must be set before any FluidAudio call.
        DownloadUtils.enforceOffline = true

        let args = parseArgs()
        guard let modelsDir = args.modelsDir else {
            fputs("Missing --models-dir\n", stderr)
            exit(1)
        }

        // Preflight: fail fast and loudly with a clear message rather than
        // letting FluidAudio's error path (which can involve deletion) run.
        let requiredFiles = [
            "Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc",
            "JointDecisionv3.mlmodelc", "parakeet_vocab.json",
        ]
        for name in requiredFiles {
            let path = modelsDir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: path.path) else {
                fputs("Model preflight failed: missing \(path.path)\n", stderr)
                exit(1)
            }
        }
        log("Model preflight OK: \(modelsDir.path)")

        let service = TranscriptionService()
        do {
            let unitsLabel = args.computeUnits.map { "\($0)" } ?? "library default (ANE)"
            log("Loading German model (compute units: \(unitsLabel))...")
            try await service.load(from: modelsDir, encoderComputeUnits: args.computeUnits)
            log("Model loaded.")
        } catch {
            fputs("FATAL: model load failed: \(error)\n", stderr)
            exit(1)
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }

        guard let port = NWEndpoint.Port(rawValue: args.port) else {
            fputs("Invalid port \(args.port)\n", stderr)
            exit(1)
        }

        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: port)
        } catch {
            fputs("FATAL: failed to bind port \(args.port): \(error)\n", stderr)
            exit(1)
        }

        let idGenerator = ConnectionIDGenerator()
        let registry = ConnectionRegistry()
        listener.newConnectionHandler = { nwConnection in
            Task {
                let id = await idGenerator.nextID()
                log("conn \(id) accepted")
                let connection = Connection(
                    id: id, nwConnection: nwConnection, transcriptionService: service,
                    registry: registry, model: args.modelInfo)
                // Register *before* starting: start() immediately registers a
                // receive callback, so the connection must already be
                // reachable from something other than this Task's own
                // about-to-end strong capture — see ConnectionRegistry's doc
                // comment for why that capture alone isn't enough.
                await registry.add(connection, id: id)
                await connection.start()
            }
        }

        let boundPort = args.port
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                log("Listening on port \(boundPort)")
            case .failed(let error):
                fputs("FATAL: listener failed: \(error)\n", stderr)
                exit(1)
            default:
                break
            }
        }

        listener.start(queue: networkQueue)

        // Keep the process alive; all real work happens on Network.framework's
        // dispatch queue and the async Connection/TranscriptionService actors.
        while true {
            try? await Task.sleep(nanoseconds: 3_600_000_000_000)
        }
    }
}
