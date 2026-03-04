# openai_compat_sample

Self-contained Genkit flow examples for `genkit_compat_oai`.

## Prerequisites

- Dart SDK `^3.10.0`
- OpenAI API key in `OPENAI_API_KEY`

## Install

```bash
dart pub get
```

## Run with Genkit Dev UI

From this folder:

```bash
genkit start -- dart run lib/simple_generation.dart
```

Swap in any file from `lib/` to load that feature's flows.

## Sample files

- `simple_generation.dart`: basic text generation + streaming
- `model_resolution.dart`: resolve/list registered actions in the registry
- `tool_calling.dart`: tool/function calling + streaming
- `structured_output.dart`: JSON-constrained output
- `embeddings.dart`: embedding generation and vector preview
- `image_generation.dart`: image generation with `gpt-image-1`
- `speech_synthesis.dart`: text-to-speech with `gpt-4o-mini-tts`
- `audio_transcription.dart`: transcription + translation from local audio files

## Notes

- `audio_transcription.dart` expects a local audio file path as flow input.
- Audio is converted to a base64 data URL before sending to the model.
