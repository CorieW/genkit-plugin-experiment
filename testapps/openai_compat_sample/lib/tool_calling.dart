import 'dart:io';
import 'dart:math';

import 'package:genkit/genkit.dart';
import 'package:genkit_compat_oai/genkit_compat_oai.dart';
import 'package:schemantic/schemantic.dart';

final class _WeatherToolInputSchema
    extends SchemanticType<Map<String, dynamic>> {
  const _WeatherToolInputSchema();

  @override
  Map<String, dynamic> parse(Object? json) {
    if (json is! Map) {
      throw ArgumentError('Weather input must be a JSON object.');
    }
    final map = Map<String, dynamic>.from(json);
    final location = (map['location'] as String?)?.trim();
    if (location == null || location.isEmpty) {
      throw ArgumentError('location is required');
    }
    final unit = (map['unit'] as String?)?.trim().toLowerCase();
    if (unit != null && unit != 'celsius' && unit != 'fahrenheit') {
      throw ArgumentError('unit must be celsius or fahrenheit');
    }
    return <String, dynamic>{
      'location': location,
      if (unit != null) 'unit': unit,
    };
  }

  @override
  Map<String, Object?> jsonSchema({bool useRefs = false}) {
    return <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'location': <String, Object?>{
          'type': 'string',
          'description': 'City name to query weather for.',
        },
        'unit': <String, Object?>{
          'type': 'string',
          'enum': <String>['celsius', 'fahrenheit'],
          'description': 'Temperature unit.',
        },
      },
      'required': <String>['location'],
      'additionalProperties': false,
    };
  }
}

final class _WeatherToolOutputSchema
    extends SchemanticType<Map<String, dynamic>> {
  const _WeatherToolOutputSchema();

  @override
  Map<String, dynamic> parse(Object? json) {
    if (json is! Map) {
      throw ArgumentError('Weather output must be a JSON object.');
    }
    return Map<String, dynamic>.from(json);
  }

  @override
  Map<String, Object?> jsonSchema({bool useRefs = false}) {
    return <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'location': <String, Object?>{'type': 'string'},
        'unit': <String, Object?>{'type': 'string'},
        'temperature': <String, Object?>{'type': 'number'},
        'condition': <String, Object?>{'type': 'string'},
        'humidity': <String, Object?>{'type': 'integer'},
      },
      'required': <String>['location', 'unit', 'temperature', 'condition'],
      'additionalProperties': false,
    };
  }
}

const _weatherToolInputSchema = _WeatherToolInputSchema();

const _weatherToolOutputSchema = _WeatherToolOutputSchema();

Tool<Map<String, dynamic>, Map<String, dynamic>> defineWeatherTool(Genkit ai) {
  return ai.defineTool(
    name: 'getWeather',
    description:
        'Get current weather details for a location. Returns temperature, conditions, and humidity.',
    inputSchema: _weatherToolInputSchema,
    outputSchema: _weatherToolOutputSchema,
    fn: (input, _) async {
      final location = (input['location'] as String?)?.trim();
      if (location == null || location.isEmpty) {
        throw ArgumentError('location is required');
      }

      final unit = ((input['unit'] as String?) ?? 'celsius').toLowerCase();
      final random = Random();
      final tempCelsius = 8 + random.nextInt(22);
      final temperature = unit == 'fahrenheit'
          ? (tempCelsius * 9 / 5) + 32
          : tempCelsius.toDouble();
      const conditions = ['sunny', 'cloudy', 'rainy', 'windy', 'foggy'];

      return <String, dynamic>{
        'location': location,
        'unit': unit,
        'temperature': temperature,
        'condition': conditions[random.nextInt(conditions.length)],
        'humidity': 45 + random.nextInt(40),
      };
    },
  );
}

Flow<String, String, void, void> defineToolCallingFlow(
  Genkit ai,
  Tool<Map<String, dynamic>, Map<String, dynamic>> getWeather,
) {
  return ai.defineFlow(
    name: 'toolCalling',
    inputSchema: SchemanticType.string(
      defaultValue: 'What is the weather in Boston in fahrenheit?',
    ),
    outputSchema: SchemanticType.string(),
    fn: (prompt, _) async {
      final response = await ai.generate(
        model: openAI.model('gpt-4o-mini'),
        prompt: prompt,
        toolNames: [getWeather.name],
      );
      return response.text;
    },
  );
}

Flow<String, String, String, void> defineStreamedToolCallingFlow(
  Genkit ai,
  Tool<Map<String, dynamic>, Map<String, dynamic>> getWeather,
) {
  return ai.defineFlow(
    name: 'streamedToolCalling',
    inputSchema: SchemanticType.string(
      defaultValue: 'Should I carry an umbrella in Seattle right now?',
    ),
    outputSchema: SchemanticType.string(),
    streamSchema: SchemanticType.string(),
    fn: (prompt, ctx) async {
      final stream = ai.generateStream(
        model: openAI.model('gpt-4o-mini'),
        prompt: prompt,
        toolNames: [getWeather.name],
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

  final getWeather = defineWeatherTool(ai);
  defineToolCallingFlow(ai, getWeather);
  defineStreamedToolCallingFlow(ai, getWeather);
}
