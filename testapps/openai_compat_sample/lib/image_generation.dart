import 'dart:io';

import 'package:genkit/genkit.dart';
import 'package:genkit_compat_oai/genkit_compat_oai.dart';
import 'package:schemantic/schemantic.dart';

Flow<String, String, void, void> defineImageGenerationFlow(Genkit ai) {
  return ai.defineFlow(
    name: 'imageGeneration',
    inputSchema: SchemanticType.string(
      defaultValue: 'A watercolor fox reading a book in a cozy library.',
    ),
    outputSchema: SchemanticType.string(),
    fn: (prompt, _) async {
      final response = await ai.generate(
        model: openAI.model('gpt-image-1'),
        prompt: prompt,
        outputFormat: 'media',
        config: <String, dynamic>{'size': '1024x1024', 'quality': 'medium'},
      );

      final media = response.media;
      if (media == null) {
        return 'No image returned.';
      }
      return media.url;
    },
  );
}

void main() {
  final ai = Genkit(
    plugins: [openAI(apiKey: Platform.environment['OPENAI_API_KEY'])],
  );

  defineImageGenerationFlow(ai);
}
