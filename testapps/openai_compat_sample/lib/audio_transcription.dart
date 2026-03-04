import 'dart:convert';
import 'dart:io';

import 'package:genkit/genkit.dart';
import 'package:genkit_compat_oai/genkit_compat_oai.dart';
import 'package:schemantic/schemantic.dart';

String _contentTypeForPath(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.mp3')) return 'audio/mpeg';
  if (lower.endsWith('.m4a')) return 'audio/mp4';
  if (lower.endsWith('.wav')) return 'audio/wav';
  if (lower.endsWith('.webm')) return 'audio/webm';
  return 'application/octet-stream';
}

Future<String> _audioFileToDataUrl(String audioPath) async {
  final file = File(audioPath);
  if (!await file.exists()) {
    throw ArgumentError('Audio file does not exist: $audioPath');
  }

  final bytes = await file.readAsBytes();
  final contentType = _contentTypeForPath(audioPath);
  return 'data:$contentType;base64,${base64Encode(bytes)}';
}

Future<Message> _audioMessage(String audioPath, String instruction) async {
  final contentType = _contentTypeForPath(audioPath);
  final dataUrl = await _audioFileToDataUrl(audioPath);

  return Message(
    role: Role.user,
    content: <Part>[
      MediaPart(
        media: Media(contentType: contentType, url: dataUrl),
      ),
      TextPart(text: instruction),
    ],
  );
}

Flow<String, String, void, void> defineTranscriptionFlow(Genkit ai) {
  return ai.defineFlow(
    name: 'audioTranscription',
    inputSchema: SchemanticType.string(
      defaultValue: 'samples/audio/sample.wav',
      description: 'Path to a local audio file.',
    ),
    outputSchema: SchemanticType.string(),
    fn: (audioPath, _) async {
      final message = await _audioMessage(audioPath, 'Transcribe this audio.');
      final response = await ai.generate(
        model: openAI.model('whisper-1'),
        messages: <Message>[message],
        outputFormat: 'text',
      );
      return response.text;
    },
  );
}

Flow<String, String, void, void> defineTranslationFlow(Genkit ai) {
  return ai.defineFlow(
    name: 'audioTranslation',
    inputSchema: SchemanticType.string(
      defaultValue: 'samples/audio/sample.wav',
      description: 'Path to a local audio file.',
    ),
    outputSchema: SchemanticType.string(),
    fn: (audioPath, _) async {
      final message = await _audioMessage(
        audioPath,
        'Translate this audio into English.',
      );
      final response = await ai.generate(
        model: openAI.model('whisper-1'),
        messages: <Message>[message],
        outputFormat: 'text',
        config: <String, dynamic>{'translate': true},
      );
      return response.text;
    },
  );
}

void main() {
  final ai = Genkit(
    plugins: [openAI(apiKey: Platform.environment['OPENAI_API_KEY'])],
  );

  defineTranscriptionFlow(ai);
  defineTranslationFlow(ai);
}
