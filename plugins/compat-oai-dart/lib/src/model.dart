import 'dart:async';
import 'dart:convert';

import 'package:genkit/genkit.dart';
import 'package:genkit/plugin.dart';

import 'client.dart';
import 'options.dart';
import 'utils.dart';

typedef ModelRequestBuilder =
    void Function(ModelRequest req, Map<String, dynamic> params);

final Map<String, FinishReason> _finishReasonMap = <String, FinishReason>{
  'length': FinishReason.length,
  'stop': FinishReason.stop,
  'tool_calls': FinishReason.stop,
  'content_filter': FinishReason.blocked,
};

final ModelInfo genericModelInfo = ModelInfo(
  supports: <String, dynamic>{
    'multiturn': true,
    'media': true,
    'tools': true,
    'toolChoice': true,
    'systemRole': true,
  },
);

bool _isRealtimeModelName(String modelName) {
  return modelName.toLowerCase().contains('realtime');
}

String? _openAIErrorMessage(Object? body) {
  if (body == null) return null;
  if (body is Map) {
    final error = body['error'];
    if (error is Map && error['message'] is String) {
      return error['message'] as String;
    }
    return null;
  }
  if (body is String) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map && error['message'] is String) {
          return error['message'] as String;
        }
      }
    } catch (_) {
      // Keep fallback below for non-JSON bodies.
    }
    return body;
  }
  return body.toString();
}

bool _isNotChatModelError(OpenAIHttpException error) {
  final message = _openAIErrorMessage(error.body)?.toLowerCase();
  if (message == null || message.isEmpty) return false;
  return message.contains('not a chat model') ||
      message.contains('not supported in the v1/chat/completions endpoint');
}

String toOpenAIRole(Role role) {
  switch (role.value) {
    case 'user':
      return 'user';
    case 'model':
      return 'assistant';
    case 'system':
      return 'system';
    case 'tool':
      return 'tool';
    default:
      throw StateError("role ${role.value} doesn't map to an OpenAI role.");
  }
}

Map<String, dynamic> toOpenAITool(ToolDefinition tool) {
  return <String, dynamic>{
    'type': 'function',
    'function': <String, dynamic>{
      'name': tool.name,
      if (tool.description.trim().isNotEmpty) 'description': tool.description,
      if (tool.inputSchema != null)
        'parameters': _normalizeJsonSchemaForOpenAI(tool.inputSchema!),
      'strict': false,
    },
  };
}

Map<String, dynamic> _normalizeJsonSchemaForOpenAI(
  Map<String, dynamic> schema,
) {
  final normalized = _normalizeJsonSchemaNode(schema);
  if (normalized is Map<String, dynamic>) return normalized;
  if (normalized is Map) return Map<String, dynamic>.from(normalized);
  return Map<String, dynamic>.from(schema);
}

Object? _normalizeJsonSchemaNode(Object? node) {
  if (node is List) {
    return node.map(_normalizeJsonSchemaNode).toList();
  }
  if (node is! Map) {
    return node;
  }

  final normalized = <String, dynamic>{};
  node.forEach((key, value) {
    normalized[key.toString()] = _normalizeJsonSchemaNode(value);
  });

  final type = normalized['type'];
  final hasObjectShape =
      type == 'object' ||
      normalized.containsKey('properties') ||
      normalized.containsKey('additionalProperties');

  if (hasObjectShape) {
    final properties = normalized['properties'];
    if (properties is Map) {
      final normalizedProperties = <String, dynamic>{};
      properties.forEach((key, value) {
        normalizedProperties[key.toString()] = _normalizeJsonSchemaNode(value);
      });
      normalized['properties'] = normalizedProperties;
    } else {
      normalized['properties'] = <String, dynamic>{};
    }

    final additionalProperties = normalized['additionalProperties'];
    if (additionalProperties is Map && additionalProperties.isEmpty) {
      normalized['additionalProperties'] = true;
    }
  }

  return normalized;
}

bool _supportsStrictJsonSchema(Object? node) {
  if (node is List) {
    return node.every(_supportsStrictJsonSchema);
  }
  if (node is! Map) {
    return true;
  }

  final schema = Map<String, dynamic>.from(node);
  final type = schema['type'];
  final hasObjectShape =
      type == 'object' ||
      schema.containsKey('properties') ||
      schema.containsKey('additionalProperties');
  if (hasObjectShape) {
    final additionalProperties = schema['additionalProperties'];
    if (additionalProperties != false) {
      return false;
    }
    final properties = schema['properties'];
    if (properties is! Map) return false;
    for (final value in properties.values) {
      if (!_supportsStrictJsonSchema(value)) return false;
    }
  }

  for (final key in <String>['items', 'anyOf', 'oneOf', 'allOf']) {
    if (schema.containsKey(key) && !_supportsStrictJsonSchema(schema[key])) {
      return false;
    }
  }
  return true;
}

bool _isLooseJsonObjectSchema(Map<String, dynamic> schema) {
  final type = schema['type'];
  final properties = schema['properties'];
  final additionalProperties = schema['additionalProperties'];
  return type == 'object' &&
      properties is Map &&
      properties.isEmpty &&
      additionalProperties == true;
}

bool _isImageContentType(String? contentType) {
  if (contentType == null || contentType.isEmpty) return false;
  return contentType.startsWith('image/');
}

bool _isAudioContentType(String? contentType) {
  if (contentType == null || contentType.isEmpty) return false;
  return contentType.toLowerCase().startsWith('audio/');
}

String _audioInputFormatFromContentType(String contentType) {
  final normalized = contentType.toLowerCase().split(';').first.trim();
  switch (normalized) {
    case 'audio/mpeg':
    case 'audio/mp3':
      return 'mp3';
    case 'audio/wav':
    case 'audio/x-wav':
      return 'wav';
    case 'audio/flac':
      return 'flac';
    case 'audio/opus':
      return 'opus';
    case 'audio/aac':
      return 'aac';
    case 'audio/l16':
    case 'audio/pcm':
      return 'pcm16';
    default:
      if (!normalized.startsWith('audio/')) return 'wav';
      return normalized.substring('audio/'.length);
  }
}

String _audioContentTypeFromFormat(String? format) {
  switch (format?.toLowerCase().trim()) {
    case 'mp3':
    case 'mpeg':
      return 'audio/mpeg';
    case 'wav':
      return 'audio/wav';
    case 'flac':
      return 'audio/flac';
    case 'opus':
      return 'audio/opus';
    case 'aac':
      return 'audio/aac';
    case 'pcm':
    case 'pcm16':
    case 'l16':
      return 'audio/L16';
    default:
      return 'audio/wav';
  }
}

bool _isAudioPreviewModelName(String modelName) {
  return modelName.toLowerCase().contains('audio-preview');
}

Map<String, dynamic>? _asJsonMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  return null;
}

List<String>? _asStringList(Object? value) {
  if (value is List) {
    final list = value.whereType<String>().map((item) => item.trim()).toList();
    return list.where((item) => item.isNotEmpty).toList();
  }
  return null;
}

bool _messagesContainInputAudio(List<Map<String, dynamic>> messages) {
  for (final message in messages) {
    final content = message['content'];
    if (content is! List) continue;
    for (final item in content.whereType<Map>()) {
      final typed = Map<String, dynamic>.from(item);
      if (typed['type'] == 'input_audio') {
        return true;
      }
    }
  }
  return false;
}

void _applyAudioPreviewDefaults({
  required String modelName,
  required Map<String, dynamic> body,
  required Map<String, dynamic> config,
  required bool hasInputAudio,
}) {
  if (!_isAudioPreviewModelName(modelName)) return;

  final existingModalities = _asStringList(body['modalities']) ?? <String>[];
  if (existingModalities.isEmpty && !hasInputAudio) {
    body['modalities'] = <String>['text', 'audio'];
  }

  final modalities = _asStringList(body['modalities']) ?? <String>[];
  if (!modalities.contains('audio')) return;

  final audio = _asJsonMap(body['audio']) ?? <String, dynamic>{};
  if (!audio.containsKey('voice')) {
    final voice = config['voice'];
    if (voice is String && voice.trim().isNotEmpty) {
      audio['voice'] = voice.trim();
    }
  }
  if (!audio.containsKey('format')) {
    final format = config['audioFormat'] ?? config['audio_format'];
    if (format is String && format.trim().isNotEmpty) {
      audio['format'] = format.trim();
    }
  }
  audio.putIfAbsent('voice', () => 'alloy');
  audio.putIfAbsent('format', () => 'wav');
  body['audio'] = audio;
}

void _appendAudioResponseParts(
  Map<String, dynamic> message,
  List<Part> content,
) {
  final audio = _asJsonMap(message['audio']);
  if (audio == null) return;

  final data = audio['data'];
  final format = audio['format'] as String?;
  if (data is String && data.isNotEmpty) {
    final contentType = _audioContentTypeFromFormat(format);
    content.add(
      MediaPart(
        media: Media(
          contentType: contentType,
          url: 'data:$contentType;base64,$data',
        ),
      ),
    );
  }

  final transcript = audio['transcript'];
  final hasText = content.any(
    (part) => part.text != null && part.text!.isNotEmpty,
  );
  if (transcript is String && transcript.isNotEmpty && !hasText) {
    content.add(TextPart(text: transcript));
  }
}

Map<String, String>? _extractDataFromBase64Url(String url) {
  final match = RegExp(r'^data:([^;]+);base64,(.+)$').firstMatch(url);
  if (match == null) return null;
  return <String, String>{
    'contentType': match.group(1)!,
    'data': match.group(2)!,
  };
}

const Map<String, String> _fileExtensions = <String, String>{
  'application/pdf': 'pdf',
  'application/msword': 'doc',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document':
      'docx',
  'text/plain': 'txt',
  'text/csv': 'csv',
};

String _filenameForContentType(String contentType) {
  final ext = _fileExtensions[contentType];
  return ext == null ? 'file' : 'file.$ext';
}

Map<String, dynamic> toOpenAITextAndMedia(
  Part part, [
  String visualDetailLevel = 'auto',
]) {
  if (part.text != null) {
    return <String, dynamic>{'type': 'text', 'text': part.text!};
  }
  if (part.media != null) {
    var contentType = part.media!.contentType;
    final url = part.media!.url;

    if ((contentType == null || contentType.isEmpty) &&
        url.startsWith('data:')) {
      final extracted = _extractDataFromBase64Url(url);
      if (extracted != null) {
        contentType = extracted['contentType'];
      }
    }

    if (_isAudioContentType(contentType)) {
      if (!url.startsWith('data:')) {
        throw StateError(
          'Audio URLs are not supported for chat completions. Only base64-encoded audio data URLs are supported.',
        );
      }
      final extracted = _extractDataFromBase64Url(url);
      if (extracted == null) {
        throw StateError(
          'Invalid data URL format for media: ${url.substring(0, url.length > 50 ? 50 : url.length)}...',
        );
      }
      final extractedType = extracted['contentType']!;
      return <String, dynamic>{
        'type': 'input_audio',
        'input_audio': <String, dynamic>{
          'data': extracted['data'],
          'format': _audioInputFormatFromContentType(extractedType),
        },
      };
    }

    if (contentType == null || _isImageContentType(contentType)) {
      return <String, dynamic>{
        'type': 'image_url',
        'image_url': <String, dynamic>{'url': url, 'detail': visualDetailLevel},
      };
    }

    if (url.startsWith('data:')) {
      final extracted = _extractDataFromBase64Url(url);
      if (extracted == null) {
        throw StateError(
          'Invalid data URL format for media: ${url.substring(0, url.length > 50 ? 50 : url.length)}...',
        );
      }
      return <String, dynamic>{
        'type': 'file',
        'file': <String, dynamic>{
          'filename': _filenameForContentType(extracted['contentType']!),
          'file_data': url,
        },
      };
    }

    throw StateError(
      'File URLs are not supported for chat completions. Only base64-encoded files and image URLs are supported. Content type: $contentType',
    );
  }
  throw StateError(
    'Unsupported genkit part fields encountered for current message role: ${jsonEncode(part.toJson())}.',
  );
}

List<Map<String, dynamic>> toOpenAIMessages(
  List<Message> messages, [
  String visualDetailLevel = 'auto',
]) {
  final apiMessages = <Map<String, dynamic>>[];
  for (final message in messages) {
    final role = toOpenAIRole(message.role);
    switch (role) {
      case 'user':
        final content = message.content
            .map((part) => toOpenAITextAndMedia(part, visualDetailLevel))
            .toList();
        final hasNonText = content.any((item) => item['type'] != 'text');
        if (!hasNonText) {
          for (final item in content) {
            apiMessages.add(<String, dynamic>{
              'role': role,
              'content': item['text'],
            });
          }
        } else {
          apiMessages.add(<String, dynamic>{'role': role, 'content': content});
        }
        break;
      case 'system':
        apiMessages.add(<String, dynamic>{
          'role': role,
          'content': message.text,
        });
        break;
      case 'assistant':
        final toolCalls = message.content
            .where((part) => part.isToolRequest)
            .map((part) => part.toolRequest!)
            .map(
              (tool) => <String, dynamic>{
                'id': tool.ref ?? '',
                'type': 'function',
                'function': <String, dynamic>{
                  'name': tool.name,
                  'arguments': jsonEncode(tool.input),
                },
              },
            )
            .toList();
        if (toolCalls.isNotEmpty) {
          apiMessages.add(<String, dynamic>{
            'role': role,
            'tool_calls': toolCalls,
          });
        } else {
          apiMessages.add(<String, dynamic>{
            'role': role,
            'content': message.text,
          });
        }
        break;
      case 'tool':
        final toolResponses = message.content
            .where((part) => part.isToolResponse)
            .map((part) => part.toolResponse!)
            .toList();
        for (final toolResponse in toolResponses) {
          apiMessages.add(<String, dynamic>{
            'role': role,
            'tool_call_id': toolResponse.ref ?? '',
            if (toolResponse.name.trim().isNotEmpty) 'name': toolResponse.name,
            'content': toolResponse.output is String
                ? toolResponse.output
                : jsonEncode(toolResponse.output),
          });
        }
        break;
    }
  }
  return apiMessages;
}

ToolRequestPart fromOpenAIToolCall(
  Map<String, dynamic> toolCall,
  Map<String, dynamic> choice,
) {
  final function = toolCall['function'];
  if (function is! Map<String, dynamic>) {
    throw StateError(
      'Unexpected openAI chunk choice. tool_calls was provided but one or more tool_calls is missing.',
    );
  }

  Map<String, dynamic>? parsedInput;
  final arguments = function['arguments'];
  final finishReason = choice['finish_reason'];
  if (finishReason == 'tool_calls' || finishReason == 'stop') {
    if (arguments is String && arguments.trim().isNotEmpty) {
      try {
        final parsed = jsonDecode(arguments);
        if (parsed is Map<String, dynamic>) {
          parsedInput = parsed;
        } else if (parsed is Map) {
          parsedInput = Map<String, dynamic>.from(parsed);
        }
      } catch (_) {
        // Streaming chunks may contain partial JSON arguments.
      }
    }
  }

  return ToolRequestPart(
    toolRequest: ToolRequest(
      name: function['name'] as String? ?? '',
      ref: toolCall['id'] as String?,
      input: parsedInput,
    ),
  );
}

ModelResponse fromOpenAIChoice(
  Map<String, dynamic> choice, {
  bool jsonMode = false,
}) {
  final message =
      (choice['message'] as Map?)?.cast<String, dynamic>() ??
      const <String, dynamic>{};
  final toolCalls = (message['tool_calls'] as List?)
      ?.whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList();

  final content = <Part>[];
  if (toolCalls != null && toolCalls.isNotEmpty) {
    for (final toolCall in toolCalls) {
      content.add(fromOpenAIToolCall(toolCall, choice));
    }
  } else {
    final reasoning = message['reasoning_content'];
    if (reasoning is String && reasoning.isNotEmpty) {
      content.add(ReasoningPart(reasoning: reasoning));
    }
    final text = message['content'];
    if (text is String && text.isNotEmpty) {
      content.add(TextPart(text: text));
      if (jsonMode) {
        try {
          final decoded = jsonDecode(text);
          if (decoded is Map<String, dynamic>) {
            content.add(DataPart(data: decoded));
          } else if (decoded is Map) {
            content.add(DataPart(data: Map<String, dynamic>.from(decoded)));
          }
        } catch (_) {
          // Keep text-only content when model emits non-JSON output.
        }
      }
    }
    _appendAudioResponseParts(message, content);
  }

  return ModelResponse(
    finishReason:
        _finishReasonMap[choice['finish_reason']] ?? FinishReason.other,
    message: Message(role: Role.model, content: content),
  );
}

ModelResponse fromOpenAIChunkChoice(
  Map<String, dynamic> choice, {
  bool jsonMode = false,
}) {
  final delta =
      (choice['delta'] as Map?)?.cast<String, dynamic>() ??
      const <String, dynamic>{};
  final toolCalls = (delta['tool_calls'] as List?)
      ?.whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList();

  final content = <Part>[];
  if (toolCalls != null && toolCalls.isNotEmpty) {
    for (final toolCall in toolCalls) {
      content.add(fromOpenAIToolCall(toolCall, choice));
    }
  } else {
    final reasoning = delta['reasoning_content'];
    if (reasoning is String && reasoning.isNotEmpty) {
      content.add(ReasoningPart(reasoning: reasoning));
    }
    final text = delta['content'];
    if (text is String && text.isNotEmpty) {
      content.add(TextPart(text: text));
    }
  }

  final finishReason = choice['finish_reason'] as String?;
  return ModelResponse(
    finishReason: finishReason == null
        ? FinishReason.unknown
        : (_finishReasonMap[finishReason] ?? FinishReason.other),
    message: Message(role: Role.model, content: content),
  );
}

Map<String, dynamic> toOpenAIRequestBody(
  String modelName,
  ModelRequest request, {
  ModelRequestBuilder? requestBuilder,
}) {
  final config = Map<String, dynamic>.from(
    request.config ?? const <String, dynamic>{},
  );
  final messages = toOpenAIMessages(
    request.messages,
    (config['visualDetailLevel'] ?? 'auto') as String,
  );

  final temperature = config['temperature'];
  final topP = config['topP'] ?? config['top_p'];
  final frequencyPenalty =
      config['frequencyPenalty'] ?? config['frequency_penalty'];
  final logProbs = config['logProbs'] ?? config['logprobs'];
  final presencePenalty =
      config['presencePenalty'] ?? config['presence_penalty'];
  final topLogProbs = config['topLogProbs'] ?? config['top_logprobs'];
  final stop = config['stopSequences'] ?? config['stop'];
  final modelVersion = config['version'];

  final tools = <Map<String, dynamic>>[...?request.tools?.map(toOpenAITool)];
  final toolsFromConfig = config['tools'];
  if (toolsFromConfig is List) {
    tools.addAll(
      toolsFromConfig.whereType<Map>().map((e) => Map<String, dynamic>.from(e)),
    );
  }

  final restOfConfig = Map<String, dynamic>.from(config)
    ..removeWhere(
      (key, _) => <String>{
        'temperature',
        'maxOutputTokens',
        'topK',
        'topP',
        'top_p',
        'frequencyPenalty',
        'frequency_penalty',
        'logProbs',
        'logprobs',
        'presencePenalty',
        'presence_penalty',
        'topLogProbs',
        'top_logprobs',
        'stopSequences',
        'stop',
        'version',
        'tools',
        'apiKey',
        'visualDetailLevel',
        'voice',
        'audioFormat',
        'audio_format',
      }.contains(key),
    );

  final effectiveModelName =
      modelVersion is String && modelVersion.trim().isNotEmpty
      ? modelVersion.trim()
      : modelName;
  final body = <String, dynamic>{
    'model': effectiveModelName,
    'messages': messages,
    'tools': tools.isNotEmpty ? tools : null,
    'temperature': temperature,
    'top_p': topP,
    'stop': stop,
    'frequency_penalty': frequencyPenalty,
    'presence_penalty': presencePenalty,
    'top_logprobs': topLogProbs,
    'logprobs': logProbs,
  };

  if (requestBuilder != null) {
    requestBuilder(request, body);
  } else {
    body.addAll(restOfConfig);
  }

  final responseFormat = request.output?.format;
  if (responseFormat == 'json') {
    if (request.output?.schema != null) {
      final constrained = request.output?.constrained;
      final normalizedSchema = _normalizeJsonSchemaForOpenAI(
        request.output!.schema!,
      );
      if (_isLooseJsonObjectSchema(normalizedSchema)) {
        body['response_format'] = <String, dynamic>{'type': 'json_object'};
      } else {
        final strict =
            constrained == true && _supportsStrictJsonSchema(normalizedSchema);
        body['response_format'] = <String, dynamic>{
          'type': 'json_schema',
          'json_schema': <String, dynamic>{
            'name': 'output',
            'schema': normalizedSchema,
            if (strict) 'strict': true,
          },
        };
      }
    } else {
      body['response_format'] = <String, dynamic>{'type': 'json_object'};
    }
  } else if (responseFormat == 'text') {
    body['response_format'] = <String, dynamic>{'type': 'text'};
  }

  final requestedModel = body['model'];
  final resolvedModel =
      requestedModel is String && requestedModel.trim().isNotEmpty
      ? requestedModel.trim()
      : effectiveModelName;
  _applyAudioPreviewDefaults(
    modelName: resolvedModel,
    body: body,
    config: config,
    hasInputAudio: _messagesContainInputAudio(messages),
  );

  body.removeWhere((_, value) {
    if (value == null) return true;
    if (value is bool) return !value;
    if (value is num) return value == 0;
    if (value is String) return value.isEmpty;
    if (value is List) return value.isEmpty;
    if (value is Map) return value.isEmpty;
    return false;
  });

  return body;
}

Map<String, dynamic> _aggregateStreamResponses(
  List<Map<String, dynamic>> chunks,
) {
  final content = StringBuffer();
  final reasoning = StringBuffer();
  final audioData = StringBuffer();
  final audioTranscript = StringBuffer();
  String? audioFormat;
  final toolCallsByIndex = <int, Map<String, dynamic>>{};

  String? finishReason;
  int choiceIndex = 0;
  Map<String, dynamic>? usage;

  for (final chunk in chunks) {
    final chunkUsage = chunk['usage'];
    if (chunkUsage is Map) {
      usage = Map<String, dynamic>.from(chunkUsage);
    }

    final choices = chunk['choices'];
    if (choices is! List || choices.isEmpty) {
      continue;
    }
    for (final rawChoice in choices.whereType<Map>()) {
      final choice = Map<String, dynamic>.from(rawChoice);
      if (choice['finish_reason'] is String) {
        finishReason = choice['finish_reason'] as String;
      }
      if (choice['index'] is int) {
        choiceIndex = choice['index'] as int;
      }

      final delta = choice['delta'];
      if (delta is! Map) continue;
      final deltaMap = Map<String, dynamic>.from(delta);

      if (deltaMap['reasoning_content'] is String) {
        reasoning.write(deltaMap['reasoning_content'] as String);
      }
      if (deltaMap['content'] is String) {
        content.write(deltaMap['content'] as String);
      }
      final deltaAudio = _asJsonMap(deltaMap['audio']);
      if (deltaAudio != null) {
        if (audioFormat == null && deltaAudio['format'] is String) {
          final format = (deltaAudio['format'] as String).trim();
          if (format.isNotEmpty) {
            audioFormat = format;
          }
        }
        if (deltaAudio['data'] is String) {
          audioData.write(deltaAudio['data'] as String);
        }
        if (deltaAudio['transcript'] is String) {
          audioTranscript.write(deltaAudio['transcript'] as String);
        }
      }

      final toolCalls = deltaMap['tool_calls'];
      if (toolCalls is! List) continue;
      for (final rawCall in toolCalls.whereType<Map>()) {
        final call = Map<String, dynamic>.from(rawCall);
        final index = call['index'] is int ? call['index'] as int : 0;
        final acc = toolCallsByIndex.putIfAbsent(
          index,
          () => <String, dynamic>{
            'id': null,
            'type': 'function',
            'function': <String, dynamic>{'name': null, 'arguments': ''},
          },
        );
        if (call['id'] is String && (call['id'] as String).isNotEmpty) {
          acc['id'] = call['id'];
        }
        final function = call['function'];
        if (function is! Map) continue;
        final accFunction = acc['function'] as Map<String, dynamic>;
        if (function['name'] is String &&
            (function['name'] as String).isNotEmpty) {
          accFunction['name'] = function['name'];
        }
        if (function['arguments'] is String) {
          accFunction['arguments'] =
              '${accFunction['arguments'] ?? ''}${function['arguments']}';
        }
      }
    }
  }

  final toolCalls = toolCallsByIndex.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  final toolCallList = toolCalls.map((entry) => entry.value).toList();

  final message = <String, dynamic>{
    'role': 'assistant',
    if (content.isNotEmpty) 'content': content.toString(),
    if (reasoning.isNotEmpty) 'reasoning_content': reasoning.toString(),
    if (audioData.isNotEmpty || audioTranscript.isNotEmpty)
      'audio': <String, dynamic>{
        if (audioData.isNotEmpty) 'data': audioData.toString(),
        if (audioTranscript.isNotEmpty)
          'transcript': audioTranscript.toString(),
        if (audioFormat != null) 'format': audioFormat,
      },
    if (toolCallList.isNotEmpty) 'tool_calls': toolCallList,
  };

  return <String, dynamic>{
    'choices': <Map<String, dynamic>>[
      <String, dynamic>{
        'index': choiceIndex,
        'message': message,
        'finish_reason': finishReason ?? 'stop',
        'logprobs': null,
      },
    ],
    if (usage != null) 'usage': usage,
  };
}

Future<ModelResponse> Function(
  ModelRequest? request,
  ({
    bool streamingRequested,
    void Function(ModelResponseChunk chunk) sendChunk,
    Map<String, dynamic>? context,
    Stream<ModelRequest>? inputStream,
    void init,
  })
  ctx,
)
openAIModelRunner(
  String name,
  CompatOpenAIClient defaultClient, {
  ModelRequestBuilder? requestBuilder,
  PluginOptions? pluginOptions,
}) {
  return (request, ctx) async {
    if (request == null) {
      throw GenkitException(
        'Model request is required.',
        status: StatusCodes.INVALID_ARGUMENT,
      );
    }
    final client = maybeCreateRequestScopedOpenAIClient(
      pluginOptions,
      request,
      defaultClient,
    );
    var resolvedModel = name;
    try {
      final body = toOpenAIRequestBody(
        name,
        request,
        requestBuilder: requestBuilder,
      );
      final requestedModel = body['model'];
      if (requestedModel is String && requestedModel.trim().isNotEmpty) {
        resolvedModel = requestedModel.trim();
      }
      if (_isRealtimeModelName(resolvedModel)) {
        throw GenkitException(
          'Model "$resolvedModel" uses the Realtime API and is not supported by chat completions.',
          status: StatusCodes.INVALID_ARGUMENT,
          details:
              'Use an OpenAI Realtime API client instead of generate()/chat completions for this model.',
        );
      }
      Map<String, dynamic> response;

      if (ctx.streamingRequested) {
        final chunks = <Map<String, dynamic>>[];
        await for (final chunk in client.createChatCompletionStream(
          <String, dynamic>{
            ...body,
            'stream': true,
            'stream_options': <String, dynamic>{'include_usage': true},
          },
        )) {
          chunks.add(chunk);
          final choices = chunk['choices'];
          if (choices is! List) continue;
          for (final rawChoice in choices.whereType<Map>()) {
            final choice = Map<String, dynamic>.from(rawChoice);
            final converted = fromOpenAIChunkChoice(
              choice,
              jsonMode: request.output?.format == 'json',
            );
            ctx.sendChunk(
              ModelResponseChunk(
                index: choice['index'] as int?,
                content: converted.message?.content ?? const <Part>[],
              ),
            );
          }
        }
        response = _aggregateStreamResponses(chunks);
      } else {
        response = await client.createChatCompletion(body);
      }

      final usage = (response['usage'] as Map?)?.cast<String, dynamic>();
      final choices = response['choices'];
      final standardUsage = usage == null
          ? null
          : GenerationUsage(
              inputTokens: (usage['prompt_tokens'] as num?)?.toDouble(),
              outputTokens: (usage['completion_tokens'] as num?)?.toDouble(),
              totalTokens: (usage['total_tokens'] as num?)?.toDouble(),
            );

      if (choices is! List || choices.isEmpty) {
        return ModelResponse(
          finishReason: FinishReason.stop,
          usage: standardUsage,
          raw: response,
        );
      }

      final choice = choices.first;
      if (choice is! Map) {
        return ModelResponse(
          finishReason: FinishReason.stop,
          usage: standardUsage,
          raw: response,
        );
      }
      final converted = fromOpenAIChoice(
        Map<String, dynamic>.from(choice),
        jsonMode: request.output?.format == 'json',
      );
      return ModelResponse(
        message: converted.message,
        finishReason: converted.finishReason,
        finishMessage: converted.finishMessage,
        latencyMs: converted.latencyMs,
        usage: standardUsage,
        custom: converted.custom,
        raw: response,
        request: converted.request,
        operation: converted.operation,
      );
    } on OpenAIHttpException catch (e, st) {
      if (_isNotChatModelError(e)) {
        throw GenkitException(
          'Model "$resolvedModel" is not compatible with /v1/chat/completions.',
          status: StatusCodes.INVALID_ARGUMENT,
          details: _openAIErrorMessage(e.body) ?? e.body?.toString(),
          underlyingException: e,
          stackTrace: st,
        );
      }
      var status = StatusCodes.UNKNOWN;
      switch (e.statusCode) {
        case 429:
          status = StatusCodes.RESOURCE_EXHAUSTED;
          break;
        case 404:
          status = StatusCodes.NOT_FOUND;
          break;
        case 401:
          status = StatusCodes.PERMISSION_DENIED;
          break;
        case 403:
          status = StatusCodes.UNAUTHENTICATED;
          break;
        case 400:
          status = StatusCodes.INVALID_ARGUMENT;
          break;
        case 500:
          status = StatusCodes.INTERNAL;
          break;
        case 503:
          status = StatusCodes.UNAVAILABLE;
          break;
      }
      throw GenkitException(
        e.message,
        status: status,
        details: e.body?.toString(),
        underlyingException: e,
        stackTrace: st,
      );
    }
  };
}

Model defineCompatOpenAIModel({
  required String name,
  required CompatOpenAIClient client,
  PluginOptions? pluginOptions,
  ModelRef<Map<String, dynamic>>? modelRef,
  ModelInfo? info,
  ModelRequestBuilder? requestBuilder,
}) {
  final modelName = toModelName(name, pluginOptions?.name);
  final actionName =
      modelRef?.name ?? '${pluginOptions?.name ?? 'compat-oai'}/$modelName';

  return Model(
    name: actionName,
    metadata: Map<String, dynamic>.from(
      modelMetadata(actionName, modelInfo: info ?? genericModelInfo).metadata,
    ),
    fn: openAIModelRunner(
      modelName,
      client,
      requestBuilder: requestBuilder,
      pluginOptions: pluginOptions,
    ),
  );
}

ModelRef<Map<String, dynamic>> compatOaiModelRef({
  required String name,
  String? namespace,
}) {
  final namespaced = namespace == null || name.startsWith('$namespace/')
      ? name
      : '$namespace/$name';
  return modelRef(namespaced);
}
