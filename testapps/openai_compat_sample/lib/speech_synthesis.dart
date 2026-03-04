import 'dart:io';

import 'package:genkit/genkit.dart';
import 'package:genkit_compat_oai/genkit_compat_oai.dart';
import 'package:schemantic/schemantic.dart';

Flow<String, String, void, void> defineSpeechSynthesisFlow(Genkit ai) {
  return ai.defineFlow(
    name: 'speechSynthesis',
    inputSchema: SchemanticType.string(
      defaultValue: 'Welcome to the OpenAI compatibility sample in Dart.',
    ),
    outputSchema: SchemanticType.string(),
    fn: (text, _) async {
      final response = await ai.generate(
        model: openAI.model('gpt-4o-mini-tts'),
        prompt: text,
        outputFormat: 'media',
        config: <String, dynamic>{'voice': 'alloy', 'response_format': 'mp3'},
      );

      return response.media?.url ?? 'No audio returned.';
    },
  );
}

void main() {
  final ai = Genkit(
    plugins: [openAI(apiKey: Platform.environment['OPENAI_API_KEY'])],
  );

  defineSpeechSynthesisFlow(ai);
}
