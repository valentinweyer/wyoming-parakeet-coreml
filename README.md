# wyoming-parakeet-coreml

A [Wyoming protocol](https://github.com/OHF-Voice/wyoming) speech-to-text server for Home Assistant, running Parakeet TDT v3 models on the **Apple Neural Engine** via [FluidAudio](https://github.com/FluidInference/FluidAudio) — not the GPU, not the cloud. Point `--models-dir` at any FluidAudio-compatible v3 CoreML export and it just works; model identity (name, language, attribution) is fully configurable via CLI flags, not hardcoded.

It ships configured for German by default, using [primeline's fine-tune](https://huggingface.co/primeline/parakeet-primeline) of NVIDIA's Parakeet TDT 0.6B v3 — see [Default model](#default-model-german) below — but that's a starting point, not a limitation.

## Why

Home Assistant's Wyoming integration expects an always-on background service, which makes power and memory footprint matter more than for a one-shot transcription tool — a GPU/MLX pipeline sitting idle 99% of the time waiting for a command is a worse fit than the Neural Engine. This project is a thin Wyoming-protocol wrapper around FluidAudio's CoreML/ANE inference, so any Parakeet v3 fine-tune you've converted (or the German one it ships with) can sit in the background cheaply and answer Home Assistant's Assist pipeline like any other STT engine.

## Quickstart

**1. Get a model.** Either use the [default German bundle](#default-model-german), or convert your own (see [CONVERSION.md](CONVERSION.md) — any FluidAudio-compatible v3 fine-tune works). Either way, you need the four `.mlmodelc` directories and a vocab file in a folder literally named `parakeet-tdt-0.6b-v3` (FluidAudio's loader expects that exact name regardless of which weights are inside):

```
parakeet-tdt-0.6b-v3/
  Preprocessor.mlmodelc/
  Encoder.mlmodelc/
  Decoder.mlmodelc/
  JointDecisionv3.mlmodelc/
  parakeet_vocab.json
```

**2. Build:**
```bash
swift build -c release
```

**3. Run:**
```bash
.build/release/WyomingParakeet \
  --models-dir /path/to/parakeet-tdt-0.6b-v3 \
  --port 10300 \
  --compute-units ane
```

**4. Wire into Home Assistant.** Settings → Devices & Services → Add Integration → **Wyoming Protocol** → the host running this server, port `10300`. It'll discover an `stt.*` entity; assign it to your Assist pipeline's speech-to-text step.

## Running it as a background service

See [`deploy/`](deploy/) for a LaunchAgent setup: `install.sh` lays out `/usr/local/wyoming-parakeet-de/`, ad-hoc codesigns the binary (needed for a locally-built binary to keep working across firewall prompts), and installs a per-user LaunchAgent. **It's a LaunchAgent, not a LaunchDaemon** — the ANE isn't reliably usable from the system-level daemon context, so this needs to run in a logged-in user session. That means the machine needs auto-login and sleep disabled to stay answering after a reboot; `deploy/README.md` has the details.

## CLI flags

| Flag | Default | Description |
|---|---|---|
| `--models-dir` | *(required)* | Path to the CoreML model bundle (folder must be named `parakeet-tdt-0.6b-v3`) |
| `--port` | `10300` | TCP port for the Wyoming server |
| `--compute-units` | ANE | `ane`, `gpu`, `cpu`, or `all` |
| `--model-name` | `parakeet-primeline-de` | Name advertised in Wyoming's `info` response |
| `--model-version` | `2_95_WER` | Version string advertised in `info` |
| `--language` | `de` | BCP-47 code — this is what makes HA offer the entity on the matching-language Assist pipeline |
| `--attribution-name` | `primeline / NVIDIA / FluidInference` | Attribution shown in `info` |
| `--attribution-url` | primeline's HF page | Attribution URL shown in `info` |
| `--model-description` | *(matches the default model)* | Free-text description in `info` |
| `--program-description` | *(matches the default model)* | Free-text description in `info` |

The defaults above describe the bundled German model — override them to match whatever you've pointed `--models-dir` at.

## Architecture notes

- **Wyoming framing** is a strict byte-counting parser (JSON header line + optional length-prefixed data + optional length-prefixed payload) — not delimiter-scanning past the header, so transcript text or audio payloads containing arbitrary bytes can never desynchronize it.
- **One shared `AsrManager`** (a `TranscriptionService` actor) serves every connection; loading the CoreML models costs real time and memory, so it happens once at startup, not per-connection.
- **Decoder state is per-utterance**, created fresh and discarded after each `audio-stop` — reusing it across utterances would leak context between unrelated voice commands.
- **Home Assistant handles end-of-speech detection.** The server advertises
  `requires_external_vad: true` because batch transcription waits for `audio-stop`.
  Advertising `false` leaves a live satellite stream waiting indefinitely, even
  though tests that explicitly finish their audio can succeed. After updating
  an existing installation, reload its Wyoming Protocol integration in Home
  Assistant to refresh the advertised capabilities.
- **`DownloadUtils.enforceOffline = true`** is set before any FluidAudio call. Without it, a model-load failure makes FluidAudio delete the model folder and silently re-download the *official English* v3 from HuggingFace — actively destructive if you're pointing it at a custom local bundle.
- **A dedicated `DispatchQueue`, not `.main`**, drives all `NWListener`/`NWConnection` callbacks. `DispatchQueue.main` needs an actively-pumped run loop (`RunLoop.main.run()` / `dispatchMain()`) to deliver its callbacks, and a headless `@main static func main() async` that just parks on `Task.sleep` doesn't provide one — callbacks fire once or twice from residual startup scheduling and then silently stop.
- Sub-0.3s audio clips are zero-padded rather than rejected (FluidAudio's minimum-duration guard), since HA's VAD can hand this server clips shorter than that.

## Default model (German)

Base Parakeet v3 auto-detects language per utterance with no way to force it — short German commands sometimes get decoded as English (`"wie viel Uhr ist es?"` → `"Beefy lost this."`). [primeline's fine-tune](https://huggingface.co/primeline/parakeet-primeline) fixes that and improves German WER generally, which is the itch that started this project. The converted CoreML build is published at [`ValentinWeyer/parakeet-primeline-de-coreml`](https://huggingface.co/ValentinWeyer/parakeet-primeline-de-coreml), including full-test-set WER benchmarks and a cross-check against unconverted NeMo/PyTorch inference confirming the conversion doesn't lose accuracy.

**Credits for the default model:**
- Base architecture and pretraining: [NVIDIA `parakeet-tdt-0.6b-v3`](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) (CC-BY-4.0)
- German fine-tuning: [primeline `parakeet-primeline`](https://huggingface.co/primeline/parakeet-primeline) (CC-BY-4.0)
- CoreML conversion tooling: [FluidInference `mobius`](https://github.com/FluidInference/mobius)
- Runtime SDK: [FluidInference `FluidAudio`](https://github.com/FluidInference/FluidAudio)

## License

The code in this repository is MIT licensed (see [LICENSE](LICENSE)). The default German model is CC-BY-4.0, inherited through the attribution chain above — see its [model card](https://huggingface.co/ValentinWeyer/parakeet-primeline-de-coreml) for details. If you convert and use a different model, check its license separately.
