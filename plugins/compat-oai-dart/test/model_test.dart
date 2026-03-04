import 'dart:convert';

import 'package:genkit/genkit.dart';
import 'package:genkit_compat_oai/genkit_compat_oai.dart';
import 'package:test/test.dart';

void main() {
  group('toOpenAIRole', () {
    test('maps known roles', () {
      expect(toOpenAIRole(Role.user), 'user');
      expect(toOpenAIRole(Role.model), 'assistant');
      expect(toOpenAIRole(Role.system), 'system');
      expect(toOpenAIRole(Role.tool), 'tool');
    });
  });

  group('toOpenAITool', () {
    test('adds empty properties for map-style tool schemas', () {
      final tool = ToolDefinition(
        name: 'getWeather',
        description: 'Returns weather information.',
        inputSchema: <String, dynamic>{
          'type': 'object',
          'additionalProperties': <String, dynamic>{'type': 'string'},
        },
      );

      final openAiTool = toOpenAITool(tool);
      final function = openAiTool['function'] as Map<String, dynamic>;
      final parameters = function['parameters'] as Map<String, dynamic>;
      expect(function['description'], 'Returns weather information.');
      expect(function['strict'], isFalse);
      expect(parameters['type'], 'object');
      expect(parameters['properties'], <String, dynamic>{});
      expect(parameters['additionalProperties'], <String, dynamic>{
        'type': 'string',
      });
    });

    test('normalizes empty additionalProperties to true', () {
      final tool = ToolDefinition(
        name: 'passthrough',
        description: 'Returns a dynamic map payload.',
        inputSchema: <String, dynamic>{
          'type': 'object',
          'additionalProperties': <String, dynamic>{},
        },
      );

      final openAiTool = toOpenAITool(tool);
      final function = openAiTool['function'] as Map<String, dynamic>;
      final parameters = function['parameters'] as Map<String, dynamic>;
      expect(parameters['properties'], <String, dynamic>{});
      expect(parameters['additionalProperties'], isTrue);
    });
  });

  group('toOpenAITextAndMedia', () {
    test('maps text part', () {
      final result = toOpenAITextAndMedia(TextPart(text: 'hi'));
      expect(result, <String, dynamic>{'type': 'text', 'text': 'hi'});
    });

    test('maps image part', () {
      final result = toOpenAITextAndMedia(
        MediaPart(
          media: Media(
            contentType: 'image/jpeg',
            url: 'https://example.com/image.jpg',
          ),
        ),
      );
      expect(result['type'], 'image_url');
      expect(
        (result['image_url'] as Map<String, dynamic>)['url'],
        contains('image.jpg'),
      );
    });

    test('maps data url pdf to file payload', () {
      final result = toOpenAITextAndMedia(
        MediaPart(
          media: Media(
            contentType: 'application/pdf',
            url: 'data:application/pdf;base64,SGVsbG8=',
          ),
        ),
      );
      expect(result['type'], 'file');
      expect(
        (result['file'] as Map<String, dynamic>)['file_data'],
        contains('data:application/pdf;base64'),
      );
    });

    test('maps data url audio to input_audio payload', () {
      final result = toOpenAITextAndMedia(
        MediaPart(
          media: Media(
            contentType: 'audio/wav',
            url: 'data:audio/wav;base64,aGVsbG8=',
          ),
        ),
      );
      expect(result['type'], 'input_audio');
      final inputAudio = result['input_audio'] as Map<String, dynamic>;
      expect(inputAudio['data'], 'aGVsbG8=');
      expect(inputAudio['format'], 'wav');
    });
  });

  group('toOpenAIMessages', () {
    test('maps text user/model/tool chain', () {
      final messages = <Message>[
        Message(
          role: Role.user,
          content: <Part>[TextPart(text: 'hi')],
        ),
        Message(
          role: Role.model,
          content: <Part>[TextPart(text: 'hello')],
        ),
        Message(
          role: Role.tool,
          content: <Part>[
            ToolResponsePart(
              toolResponse: ToolResponse(
                ref: 'call_1',
                name: 'toolA',
                output: <String, dynamic>{'ok': true},
              ),
            ),
          ],
        ),
      ];
      final result = toOpenAIMessages(messages);
      expect(result.length, 3);
      expect(result[0]['role'], 'user');
      expect(result[1]['role'], 'assistant');
      expect(result[2]['role'], 'tool');
      expect(result[2]['tool_call_id'], 'call_1');
      expect(result[2]['name'], 'toolA');
    });
  });

  group('fromOpenAIChoice', () {
    test('maps text response', () {
      final response = fromOpenAIChoice(<String, dynamic>{
        'finish_reason': 'stop',
        'message': <String, dynamic>{'role': 'assistant', 'content': 'Hello'},
      });
      expect(response.finishReason, FinishReason.stop);
      expect(response.message?.text, 'Hello');
    });

    test('maps json response', () {
      final response = fromOpenAIChoice(<String, dynamic>{
        'finish_reason': 'content_filter',
        'message': <String, dynamic>{
          'role': 'assistant',
          'content': jsonEncode(<String, dynamic>{'x': 1}),
        },
      }, jsonMode: true);
      expect(response.finishReason, FinishReason.blocked);
      expect(response.message?.text, contains('"x":1'));
      expect(response.message?.content.any((part) => part.isData), isTrue);
    });

    test('maps audio response data and transcript', () {
      final response = fromOpenAIChoice(<String, dynamic>{
        'finish_reason': 'stop',
        'message': <String, dynamic>{
          'role': 'assistant',
          'audio': <String, dynamic>{
            'data': 'aGVsbG8=',
            'format': 'wav',
            'transcript': 'Hello from audio',
          },
        },
      });
      final parts = response.message?.content ?? const <Part>[];
      final mediaPart = parts.firstWhere((part) => part.media != null);
      expect(mediaPart.media?.contentType, 'audio/wav');
      expect(mediaPart.media?.url, 'data:audio/wav;base64,aGVsbG8=');
      expect(parts.any((part) => part.text == 'Hello from audio'), isTrue);
    });

    test('parses tool arguments when finish_reason is stop', () {
      final part = fromOpenAIToolCall(
        <String, dynamic>{
          'id': 'call_1',
          'function': <String, dynamic>{
            'name': 'getWeather',
            'arguments': '{"location":"Boston","unit":"celsius"}',
          },
        },
        <String, dynamic>{'finish_reason': 'stop'},
      );

      expect(part.toolRequest?.name, 'getWeather');
      expect(part.toolRequest?.ref, 'call_1');
      expect(part.toolRequest?.input, <String, dynamic>{
        'location': 'Boston',
        'unit': 'celsius',
      });
    });
  });

  group('toOpenAIRequestBody', () {
    test('maps request and sets json_schema response format', () {
      final request = ModelRequest(
        messages: <Message>[
          Message(
            role: Role.user,
            content: <Part>[TextPart(text: 'hello')],
          ),
        ],
        output: OutputConfig(
          format: 'json',
          schema: <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'foo': <String, dynamic>{'type': 'string'},
            },
            'required': <String>['foo'],
          },
        ),
      );

      final body = toOpenAIRequestBody('gpt-4o', request);
      expect(body['model'], 'gpt-4o');
      expect(body['messages'], isA<List>());
      final responseFormat = body['response_format'] as Map<String, dynamic>;
      expect(responseFormat['type'], 'json_schema');
    });

    test('adds empty properties for map-style json schema output format', () {
      final request = ModelRequest(
        messages: <Message>[
          Message(
            role: Role.user,
            content: <Part>[TextPart(text: 'hello')],
          ),
        ],
        output: OutputConfig(
          format: 'json',
          schema: <String, dynamic>{
            'type': 'object',
            'additionalProperties': <String, dynamic>{'type': 'string'},
          },
        ),
      );

      final body = toOpenAIRequestBody('gpt-4o', request);
      final responseFormat = body['response_format'] as Map<String, dynamic>;
      final jsonSchema = responseFormat['json_schema'] as Map<String, dynamic>;
      final schema = jsonSchema['schema'] as Map<String, dynamic>;

      expect(schema['type'], 'object');
      expect(schema['properties'], <String, dynamic>{});
      expect(schema['additionalProperties'], <String, dynamic>{
        'type': 'string',
      });
    });

    test('falls back to json_object for unconstrained map-like schemas', () {
      final request = ModelRequest(
        messages: <Message>[
          Message(
            role: Role.user,
            content: <Part>[TextPart(text: 'hello')],
          ),
        ],
        output: OutputConfig(
          format: 'json',
          schema: <String, dynamic>{
            'type': 'object',
            'additionalProperties': <String, dynamic>{},
          },
        ),
      );

      final body = toOpenAIRequestBody('gpt-4o', request);
      final responseFormat = body['response_format'] as Map<String, dynamic>;
      expect(responseFormat['type'], 'json_object');
    });

    test('sets strict for constrained json output', () {
      final request = ModelRequest(
        messages: <Message>[
          Message(
            role: Role.user,
            content: <Part>[TextPart(text: 'hello')],
          ),
        ],
        output: OutputConfig(
          format: 'json',
          constrained: true,
          schema: <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'value': <String, dynamic>{'type': 'string'},
            },
            'additionalProperties': false,
            'required': <String>['value'],
          },
        ),
      );

      final body = toOpenAIRequestBody('gpt-4o', request);
      final responseFormat = body['response_format'] as Map<String, dynamic>;
      final jsonSchema = responseFormat['json_schema'] as Map<String, dynamic>;
      expect(jsonSchema['strict'], isTrue);
    });

    test(
      'does not set strict when constrained schema is not strict-compatible',
      () {
        final request = ModelRequest(
          messages: <Message>[
            Message(
              role: Role.user,
              content: <Part>[TextPart(text: 'hello')],
            ),
          ],
          output: OutputConfig(
            format: 'json',
            constrained: true,
            schema: <String, dynamic>{
              'type': 'object',
              'additionalProperties': true,
            },
          ),
        );

        final body = toOpenAIRequestBody('gpt-4o', request);
        final responseFormat = body['response_format'] as Map<String, dynamic>;
        expect(responseFormat['type'], 'json_object');
      },
    );

    test('adds default audio settings for audio-preview models', () {
      final request = ModelRequest(
        messages: <Message>[
          Message(
            role: Role.user,
            content: <Part>[TextPart(text: 'say hello')],
          ),
        ],
      );

      final body = toOpenAIRequestBody('gpt-4o-audio-preview', request);
      expect(body['modalities'], <String>['text', 'audio']);
      expect(body['audio'], <String, dynamic>{
        'voice': 'alloy',
        'format': 'wav',
      });
    });

    test('uses explicit audio config for audio-preview models', () {
      final request = ModelRequest(
        messages: <Message>[
          Message(
            role: Role.user,
            content: <Part>[TextPart(text: 'say hello')],
          ),
        ],
        config: <String, dynamic>{'voice': 'echo', 'audio_format': 'mp3'},
      );

      final body = toOpenAIRequestBody('gpt-4o-audio-preview', request);
      expect(body['modalities'], <String>['text', 'audio']);
      expect(body['audio'], <String, dynamic>{
        'voice': 'echo',
        'format': 'mp3',
      });
      expect(body.containsKey('voice'), isFalse);
      expect(body.containsKey('audio_format'), isFalse);
    });

    test(
      'does not force output audio when request already has input audio',
      () {
        final request = ModelRequest(
          messages: <Message>[
            Message(
              role: Role.user,
              content: <Part>[
                MediaPart(
                  media: Media(
                    contentType: 'audio/wav',
                    url: 'data:audio/wav;base64,aGVsbG8=',
                  ),
                ),
              ],
            ),
          ],
        );

        final body = toOpenAIRequestBody('gpt-4o-audio-preview', request);
        expect(body.containsKey('modalities'), isFalse);
        final messages = body['messages'] as List<dynamic>;
        final content =
            (messages.first as Map<String, dynamic>)['content'] as List;
        expect((content.first as Map<String, dynamic>)['type'], 'input_audio');
      },
    );
  });
}
