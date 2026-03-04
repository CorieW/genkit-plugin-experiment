import 'dart:convert';
import 'dart:io';

import 'package:genkit/genkit.dart';
import 'package:genkit_compat_oai/genkit_compat_oai.dart';
import 'package:schemantic/schemantic.dart';

final class _StructuredOutputSchema
    extends SchemanticType<Map<String, dynamic>> {
  const _StructuredOutputSchema();

  @override
  Map<String, dynamic> parse(Object? json) {
    if (json is! Map) {
      throw ArgumentError('Structured output must be a JSON object.');
    }
    final map = Map<String, dynamic>.from(json);
    final summary = (map['summary'] as String?)?.trim();
    final sentiment = (map['sentiment'] as String?)?.trim().toLowerCase();
    final rawKeywords = map['keywords'];
    if (summary == null || summary.isEmpty) {
      throw ArgumentError('summary is required');
    }
    if (sentiment == null ||
        !<String>{'positive', 'neutral', 'negative'}.contains(sentiment)) {
      throw ArgumentError('sentiment must be positive, neutral, or negative');
    }
    if (rawKeywords is! List) {
      throw ArgumentError('keywords must be an array');
    }
    final keywords = rawKeywords
        .whereType<String>()
        .map((keyword) => keyword.trim())
        .where((keyword) => keyword.isNotEmpty)
        .toList();
    return <String, dynamic>{
      'summary': summary,
      'sentiment': sentiment,
      'keywords': keywords,
    };
  }

  @override
  Map<String, Object?> jsonSchema({bool useRefs = false}) {
    return <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'summary': <String, Object?>{'type': 'string'},
        'sentiment': <String, Object?>{
          'type': 'string',
          'enum': <String>['positive', 'neutral', 'negative'],
        },
        'keywords': <String, Object?>{
          'type': 'array',
          'items': <String, Object?>{'type': 'string'},
        },
      },
      'required': <String>['summary', 'sentiment', 'keywords'],
      'additionalProperties': false,
    };
  }
}

const _structuredOutputSchema = _StructuredOutputSchema();

Flow<String, String, void, void> defineStructuredOutputFlow(Genkit ai) {
  return ai.defineFlow(
    name: 'structuredOutput',
    inputSchema: SchemanticType.string(
      defaultValue: 'Dart 3.10 adds quality-of-life features for developers.',
    ),
    outputSchema: SchemanticType.string(),
    fn: (inputText, _) async {
      final response = await ai.generate(
        model: openAI.model('gpt-4o-mini'),
        prompt:
            '''
Analyze the input text and return JSON with keys:
- summary: string
- sentiment: "positive" | "neutral" | "negative"
- keywords: string[]

Input:
$inputText
''',
        outputFormat: 'json',
        outputSchema: _structuredOutputSchema,
        outputConstrained: true,
      );

      return const JsonEncoder.withIndent(
        '  ',
      ).convert(response.output ?? const <String, dynamic>{});
    },
  );
}

void main() {
  final ai = Genkit(
    plugins: [openAI(apiKey: Platform.environment['OPENAI_API_KEY'])],
  );

  defineStructuredOutputFlow(ai);
}
