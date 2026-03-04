import 'dart:async';
import 'dart:io';

import 'package:genkit/genkit.dart';
import 'package:genkit_compat_oai/genkit_compat_oai.dart';

import '../lib/audio_transcription.dart' as audio_transcription;
import '../lib/embeddings.dart' as embeddings;
import '../lib/image_generation.dart' as image_generation;
import '../lib/model_resolution.dart' as model_resolution;
import '../lib/simple_generation.dart' as simple_generation;
import '../lib/speech_synthesis.dart' as speech_synthesis;
import '../lib/structured_output.dart' as structured_output;
import '../lib/tool_calling.dart' as tool_calling;

typedef RunCase = Future<String> Function();

class _FlowCase {
  final String name;
  final RunCase run;

  const _FlowCase(this.name, this.run);
}

Future<void> main() async {
  final apiKey = Platform.environment['OPENAI_API_KEY'];
  if (apiKey == null || apiKey.isEmpty) {
    stderr.writeln('OPENAI_API_KEY is required.');
    exitCode = 2;
    return;
  }

  final ai = Genkit(plugins: [openAI(apiKey: apiKey)]);
  final weatherTool = tool_calling.defineWeatherTool(ai);

  final simple = simple_generation.defineSimpleGenerationFlow(ai);
  final streamedSimple = simple_generation.defineStreamedSimpleGenerationFlow(
    ai,
  );
  final modelResolution = model_resolution.defineModelResolutionFlow(ai);
  final actionList = model_resolution.defineActionListFlow(ai);
  final toolCalling = tool_calling.defineToolCallingFlow(ai, weatherTool);
  final streamedToolCalling = tool_calling.defineStreamedToolCallingFlow(
    ai,
    weatherTool,
  );
  final structured = structured_output.defineStructuredOutputFlow(ai);
  final embed = embeddings.defineEmbeddingPreviewFlow(ai);
  final image = image_generation.defineImageGenerationFlow(ai);
  final speech = speech_synthesis.defineSpeechSynthesisFlow(ai);
  final transcription = audio_transcription.defineTranscriptionFlow(ai);
  final translation = audio_transcription.defineTranslationFlow(ai);

  final flowCases = <_FlowCase>[
    _FlowCase(
      'simpleGeneration',
      () => simple
          .run('Give one sentence about typed APIs.')
          .then((r) => r.result),
    ),
    _FlowCase(
      'streamedSimpleGeneration',
      () => _runStreamedFlow(
        streamedSimple,
        'Write a two-line haiku about static analysis.',
      ),
    ),
    _FlowCase(
      'modelResolution',
      () => modelResolution.run('gpt-4o-mini').then((r) => r.result),
    ),
    _FlowCase(
      'actionList',
      () => actionList.run('model').then((r) => r.result),
    ),
    _FlowCase(
      'toolCalling',
      () => toolCalling
          .run('What is the weather in London in celsius?')
          .then((r) => r.result),
    ),
    _FlowCase(
      'streamedToolCalling',
      () => _runStreamedFlow(
        streamedToolCalling,
        'Do I need a jacket in Boston right now?',
      ),
    ),
    _FlowCase(
      'structuredOutput',
      () => structured
          .run('Genkit improves reliability of LLM pipelines.')
          .then((r) => r.result),
    ),
    _FlowCase(
      'embeddingPreview',
      () => embed
          .run('Embeddings map semantically similar text close together.')
          .then((r) => r.result),
    ),
    _FlowCase(
      'imageGeneration',
      () => image
          .run('A sketch of a lighthouse at sunrise.')
          .then((r) => r.result),
    ),
    _FlowCase(
      'speechSynthesis',
      () => speech
          .run(
            'Testing text to speech from the Genkit OpenAI compatibility plugin.',
          )
          .then((r) => r.result),
    ),
    _FlowCase(
      'audioTranscription',
      () => transcription.run('../sample.wav').then((r) => r.result),
    ),
    _FlowCase(
      'audioTranslation',
      () => translation.run('../sample.wav').then((r) => r.result),
    ),
  ];

  final failures = <String>[];
  for (final flowCase in flowCases) {
    stdout.writeln('--- RUN ${flowCase.name} ---');
    try {
      final output = await flowCase.run();
      stdout.writeln(_preview(output));
    } catch (error, stackTrace) {
      failures.add(flowCase.name);
      stderr.writeln('FAILED ${flowCase.name}: $error');
      stderr.writeln(stackTrace);
    }
  }

  if (failures.isNotEmpty) {
    stderr.writeln('\nFailing flows: ${failures.join(', ')}');
    exitCode = 1;
  } else {
    stdout.writeln('\nAll flows passed.');
  }
}

Future<String> _runStreamedFlow(
  Flow<String, String, String, void> flow,
  String input,
) async {
  final stream = flow.stream(input);
  final chunks = <String>[];
  await for (final chunk in stream) {
    chunks.add(chunk);
  }
  final finalResult = await stream.onResult;
  return 'chunks=${chunks.length}; final=${_preview(finalResult)}';
}

String _preview(String value) {
  final compact = value.replaceAll('\n', r'\n');
  const maxLength = 240;
  if (compact.length <= maxLength) return compact;
  return '${compact.substring(0, maxLength)}...';
}
