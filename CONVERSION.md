# Converting a different fine-tune

This server works with any FluidAudio-compatible Parakeet TDT v3 CoreML
export — the German primeline model is just the one it ships with by
default. Notes from converting that one, if you want to convert a different
language's fine-tune yourself.

## Before converting anything: check the tokenizer

If the fine-tune retrained its tokenizer (different vocab size or a
different blank token index than base v3's 8192), FluidAudio's `.v3` loader
hardcodes `blankId = 8192` and won't work without a fork. Check this first —
it's a five-minute SentencePiece check, versus hours of conversion work you'd
have to redo:

```python
import sentencepiece as spm
sp = spm.SentencePieceProcessor()
sp.load("path/to/tokenizer.model")  # extract from inside the .nemo tar first
assert sp.get_piece_size() == 8192
```

primeline's fine-tune passed this check with a byte-identical vocabulary to
base v3 — expected for a fine-tune (as opposed to a retrain), since that
doesn't touch the tokenizer.

## Conversion tooling

Use FluidInference's own [mobius](https://github.com/FluidInference/mobius)
export script, pointed at your `.nemo` checkpoint instead of the base model —
no code changes needed if the tokenizer check above passes:

```bash
git clone https://github.com/FluidInference/mobius
cd mobius/models/stt/parakeet-tdt-v3-0.6b/coreml
uv sync   # pinned environment: torch 2.7, coremltools 9.0b1, python 3.10.12

uv run python convert-parakeet.py \
  --nemo-path /path/to/your-checkpoint.nemo \
  --output-dir out/ \
  --compute-precision float16
```

This exports 7 `.mlpackage` components; only 4 are needed for FluidAudio's
`.v3` path — the rest (`parakeet_mel_encoder`, `parakeet_joint`,
`parakeet_joint_decision` without `_single_step`) are unused fusion/debug
variants:

| Exported | → | FluidAudio expects |
|---|---|---|
| `parakeet_preprocessor.mlpackage` | → | `Preprocessor.mlmodelc` |
| `parakeet_encoder.mlpackage` | → | `Encoder.mlmodelc` |
| `parakeet_decoder.mlpackage` | → | `Decoder.mlmodelc` |
| `parakeet_joint_decision_single_step.mlpackage` | → | `JointDecisionv3.mlmodelc` |

The single-step joint decision variant specifically is the one with
`top_k_ids`/`top_k_logits` outputs — FluidAudio's v3 decoder requires those
for its language-script filtering. Verify they're present before compiling
(`ct.models.MLModel(path, skip_model_load=True).get_spec().description.output`).

## Compiling `.mlpackage` → `.mlmodelc`

If you don't have Xcode (only Command Line Tools), `xcrun coremlcompiler`
isn't available — use `coremltools` directly instead:

```python
import coremltools as ct
ct.utils.compile_model("parakeet_encoder.mlpackage", destination_path="Encoder.mlmodelc")
```

Note `destination_path` must literally end in `.mlmodelc` and is the exact
final path, not a directory to place the result inside.

## Assembling the bundle

Put the four compiled `.mlmodelc` directories plus a vocabulary file
(`parakeet_vocab.json` — copy the base model's if your tokenizer check above
passed, since it's identical) into a folder **named exactly
`parakeet-tdt-0.6b-v3`**. FluidAudio's `AsrModels.load(from:)` derives this
name internally regardless of what's actually inside, so getting the folder
name right matters more than anything else here.

**Set `DownloadUtils.enforceOffline = true`** before loading (this server
already does). Without it, any load failure — including a bad conversion —
makes FluidAudio delete the folder and silently re-download the official
English v3 instead. Keep a backup copy of your bundle until you've confirmed
it loads and transcribes correctly.

## Validating

At minimum, load the bundle and transcribe a few known utterances, comparing
against the base English v3 model on the same files to confirm the output is
sane and in the right language. For anything you're going to rely on, a
proper WER comparison against a public test set (and, if the fine-tune
publishes benchmark numbers, against those) is worth the time — normalization
choices matter more than you'd expect, so a same-harness control run against
base v3 (scored against *its* published numbers) is the cheapest way to tell
whether a WER gap is real or just measurement noise from decode settings you
don't control.
