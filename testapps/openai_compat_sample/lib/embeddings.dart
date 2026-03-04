import 'dart:convert';
import 'dart:io';

import 'package:genkit/genkit.dart';
import 'package:genkit_compat_oai/genkit_compat_oai.dart';
import 'package:schemantic/schemantic.dart';

Flow<String, String, void, void> defineEmbeddingPreviewFlow(Genkit ai) {
  return ai.defineFlow(
    name: 'embeddingPreview',
    inputSchema: SchemanticType.string(
      defaultValue: 'Genkit helps teams ship production AI features faster.',
    ),
    outputSchema: SchemanticType.string(),
    fn: (text, _) async {
      final embeddings = await ai.embed(
        embedder: openAI.embedder('text-embedding-3-small'),
        document: DocumentData(content: <Part>[TextPart(text: text)]),
      );

      if (embeddings.isEmpty) {
        return jsonEncode(<String, dynamic>{
          'error': 'No embeddings returned.',
        });
      }

      final vector = embeddings.first.embedding;
      return const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
        'model': 'text-embedding-3-small',
        'dimensions': vector.length,
        'preview': vector.take(8).toList(),
      });
    },
  );
}

void main() {
  final ai = Genkit(
    plugins: [openAI(apiKey: Platform.environment['OPENAI_API_KEY'])],
  );

  defineEmbeddingPreviewFlow(ai);
}
