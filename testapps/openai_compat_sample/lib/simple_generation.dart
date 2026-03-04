import 'dart:io';

import 'package:genkit/genkit.dart';
import 'package:genkit_compat_oai/genkit_compat_oai.dart';
import 'package:schemantic/schemantic.dart';

Flow<String, String, void, void> defineSimpleGenerationFlow(Genkit ai) {
  return ai.defineFlow(
    name: 'simpleGeneration',
    inputSchema: SchemanticType.string(
      defaultValue: 'Explain why typed languages are useful in one paragraph.',
    ),
    outputSchema: SchemanticType.string(),
    fn: (prompt, _) async {
      final response = await ai.generate(
        model: openAI.model('gpt-4o-mini'),
        prompt: prompt,
      );
      return response.text;
    },
  );
}

Flow<String, String, String, void> defineStreamedSimpleGenerationFlow(
  Genkit ai,
) {
  return ai.defineFlow(
    name: 'streamedSimpleGeneration',
    inputSchema: SchemanticType.string(
      defaultValue: 'Write a short limerick about code reviews.',
    ),
    outputSchema: SchemanticType.string(),
    streamSchema: SchemanticType.string(),
    fn: (prompt, ctx) async {
      final stream = ai.generateStream(
        model: openAI.model('gpt-4o-mini'),
        prompt: prompt,
      );

      await for (final chunk in stream) {
        if (ctx.streamingRequested) {
          ctx.sendChunk(chunk.text);
        }
      }

      return (await stream.onResult).text;
    },
  );
}

void main() {
  final ai = Genkit(
    plugins: [openAI(apiKey: Platform.environment['OPENAI_API_KEY'])],
  );

  defineSimpleGenerationFlow(ai);
  defineStreamedSimpleGenerationFlow(ai);
}
