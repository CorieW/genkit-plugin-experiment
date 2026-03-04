import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:genkit/genkit.dart';
import 'package:genkit/plugin.dart';

import 'client.dart';
import 'model.dart';
import 'options.dart';
import 'utils.dart';

final ModelInfo realtimeModelInfo = ModelInfo(
  supports: <String, dynamic>{
    'multiturn': true,
    'media': true,
    'tools': true,
    'toolChoice': true,
    'systemRole': true,
    'output': <String>['text', 'json'],
  },
);

bool isRealtimeModelName(String modelName) {
  return modelName.toLowerCase().contains('realtime');
}

typedef RealtimeModelRunner =
    Future<ModelResponse> Function(
      Stream<ModelRequest> inputStream,
      ActionFnArg<ModelResponseChunk, ModelRequest, ModelRequest> ctx,
    );

RealtimeModelRunner openAIRealtimeModelRunner(
  String name,
  CompatOpenAIClient defaultClient, {
  PluginOptions? pluginOptions,
}) {
  return (inputStream, ctx) async {
    final initRequest = ctx.init;
    final client = maybeCreateRequestScopedOpenAIClient(
      pluginOptions,
      initRequest,
      defaultClient,
    );
    final modelName = _resolveRealtimeModelName(name, initRequest);
    if (!isRealtimeModelName(modelName)) {
      throw GenkitException(
        'Model "$modelName" is not a realtime model.',
        status: StatusCodes.INVALID_ARGUMENT,
      );
    }

    WebSocket? socket;
    StreamIterator<dynamic>? iterator;
    ModelResponse? lastResponse;

    try {
      socket = await client.connectRealtime(model: modelName);
      iterator = StreamIterator<dynamic>(socket);

      final sessionUpdate = _buildSessionUpdateEvent(initRequest);
      if (sessionUpdate != null) {
        _sendRealtimeEvent(socket, sessionUpdate);
      }

      await for (final request in inputStream) {
        final events = _buildConversationItemEvents(request);
        for (final event in events) {
          _sendRealtimeEvent(socket, event);
        }
        _sendRealtimeEvent(socket, _buildResponseCreateEvent(request));
        lastResponse = await _consumeRealtimeResponse(
          iterator,
          ctx,
          request.output?.format == 'json',
        );
      }

      return lastResponse ??
          ModelResponse(
            finishReason: FinishReason.stop,
            message: Message(role: Role.model, content: <Part>[]),
          );
    } on OpenAIHttpException catch (e, st) {
      throw GenkitException(
        e.message,
        status: _statusFromRealtimeException(e),
        details: e.body?.toString(),
        underlyingException: e,
        stackTrace: st,
      );
    } finally {
      await iterator?.cancel();
      await socket?.close();
    }
  };
}

BidiModel defineCompatOpenAIRealtimeModel({
  required String name,
  required CompatOpenAIClient client,
  PluginOptions? pluginOptions,
  ModelInfo? info,
}) {
  final modelName = toModelName(name, pluginOptions?.name);
  final actionName = '${pluginOptions?.name ?? 'compat-oai'}/$modelName';
  final runner = openAIRealtimeModelRunner(
    modelName,
    client,
    pluginOptions: pluginOptions,
  );

  return BidiModel(
    name: actionName,
    metadata: Map<String, dynamic>.from(
      modelMetadata(actionName, modelInfo: info ?? realtimeModelInfo).metadata,
    ),
    fn: (_, ctx) async {
      final inputStream = ctx.inputStream;
      if (inputStream == null) {
        throw GenkitException(
          'Realtime model "$actionName" called without input stream.',
          status: StatusCodes.INVALID_ARGUMENT,
        );
      }
      return runner(inputStream, (
        streamingRequested: ctx.streamingRequested,
        sendChunk: ctx.sendChunk,
        context: ctx.context,
        inputStream: ctx.inputStream,
        init: ctx.init,
      ));
    },
  );
}

String _resolveRealtimeModelName(String fallback, ModelRequest? initRequest) {
  final configured = initRequest?.config?['version'];
  if (configured is String && configured.trim().isNotEmpty) {
    return configured.trim();
  }
  return fallback;
}

Map<String, dynamic>? _buildSessionUpdateEvent(ModelRequest? initRequest) {
  if (initRequest == null) return null;

  final config = Map<String, dynamic>.from(
    initRequest.config ?? const <String, dynamic>{},
  );
  final session = Map<String, dynamic>.from(
    _asJsonMap(config['session']) ?? const <String, dynamic>{},
  );

  final instructions = initRequest.messages
      .where((m) => m.role.value == Role.system.value)
      .map((m) => m.text.trim())
      .where((text) => text.isNotEmpty)
      .join('\n\n');
  if (instructions.isNotEmpty && !session.containsKey('instructions')) {
    session['instructions'] = instructions;
  }

  if (!session.containsKey('tools')) {
    final tools = <Map<String, dynamic>>[
      ...?initRequest.tools?.map(toOpenAITool),
    ];
    if (tools.isNotEmpty) {
      session['tools'] = tools;
    }
  }
  if (initRequest.toolChoice != null && !session.containsKey('tool_choice')) {
    session['tool_choice'] = initRequest.toolChoice;
  }

  if (config['temperature'] != null && !session.containsKey('temperature')) {
    session['temperature'] = config['temperature'];
  }
  final maxOutputTokens =
      config['maxOutputTokens'] ?? config['max_output_tokens'];
  if (maxOutputTokens != null && !session.containsKey('max_output_tokens')) {
    session['max_output_tokens'] = maxOutputTokens;
  }
  if (config['modalities'] != null && !session.containsKey('modalities')) {
    session['modalities'] = config['modalities'];
  }
  if (config['voice'] != null && !session.containsKey('voice')) {
    session['voice'] = config['voice'];
  }

  session.removeWhere((_, value) {
    if (value == null) return true;
    if (value is String) return value.isEmpty;
    if (value is List) return value.isEmpty;
    if (value is Map) return value.isEmpty;
    return false;
  });

  if (session.isEmpty) return null;
  return <String, dynamic>{'type': 'session.update', 'session': session};
}

List<Map<String, dynamic>> _buildConversationItemEvents(ModelRequest request) {
  final events = <Map<String, dynamic>>[];

  for (final message in request.messages) {
    final role = message.role.value;
    if (role == Role.system.value) {
      continue;
    }

    if (role == Role.user.value) {
      final content = <Map<String, dynamic>>[];
      for (final part in message.content) {
        if (part.text != null && part.text!.isNotEmpty) {
          content.add(<String, dynamic>{
            'type': 'input_text',
            'text': part.text!,
          });
          continue;
        }
        if (part.media != null) {
          content.add(<String, dynamic>{
            'type': 'input_image',
            'image_url': part.media!.url,
          });
          continue;
        }
        if (part.data != null && part.data!.isNotEmpty) {
          content.add(<String, dynamic>{
            'type': 'input_text',
            'text': jsonEncode(part.data),
          });
        }
      }

      if (content.isNotEmpty) {
        events.add(<String, dynamic>{
          'type': 'conversation.item.create',
          'item': <String, dynamic>{
            'type': 'message',
            'role': 'user',
            'content': content,
          },
        });
      }
      continue;
    }

    if (role == Role.tool.value) {
      final toolResponses = message.content
          .where((part) => part.isToolResponse)
          .map((part) => part.toolResponse!)
          .toList();
      for (final toolResponse in toolResponses) {
        if (toolResponse.ref == null || toolResponse.ref!.isEmpty) {
          continue;
        }
        events.add(<String, dynamic>{
          'type': 'conversation.item.create',
          'item': <String, dynamic>{
            'type': 'function_call_output',
            'call_id': toolResponse.ref,
            'output': toolResponse.output is String
                ? toolResponse.output
                : jsonEncode(toolResponse.output),
          },
        });
      }
      continue;
    }

    if (role == Role.model.value) {
      final assistantText = message.text.trim();
      if (assistantText.isNotEmpty) {
        events.add(<String, dynamic>{
          'type': 'conversation.item.create',
          'item': <String, dynamic>{
            'type': 'message',
            'role': 'assistant',
            'content': <Map<String, dynamic>>[
              <String, dynamic>{'type': 'output_text', 'text': assistantText},
            ],
          },
        });
      }
    }
  }

  return events;
}

Map<String, dynamic> _buildResponseCreateEvent(ModelRequest request) {
  final config = Map<String, dynamic>.from(
    request.config ?? const <String, dynamic>{},
  );
  final response = Map<String, dynamic>.from(
    _asJsonMap(config['response']) ?? const <String, dynamic>{},
  );

  if (!response.containsKey('modalities') && config['modalities'] != null) {
    response['modalities'] = config['modalities'];
  }
  if (!response.containsKey('temperature') && config['temperature'] != null) {
    response['temperature'] = config['temperature'];
  }
  final maxOutputTokens =
      config['maxOutputTokens'] ?? config['max_output_tokens'];
  if (!response.containsKey('max_output_tokens') && maxOutputTokens != null) {
    response['max_output_tokens'] = maxOutputTokens;
  }
  if (!response.containsKey('tool_choice') && request.toolChoice != null) {
    response['tool_choice'] = request.toolChoice;
  }

  if (request.output?.format == 'json' && !response.containsKey('format')) {
    if (request.output?.schema != null) {
      response['format'] = <String, dynamic>{
        'type': 'json_schema',
        'name': 'output',
        'schema': request.output!.schema,
      };
    } else {
      response['format'] = <String, dynamic>{'type': 'json_object'};
    }
  }

  response.removeWhere((_, value) {
    if (value == null) return true;
    if (value is String) return value.isEmpty;
    if (value is List) return value.isEmpty;
    if (value is Map) return value.isEmpty;
    return false;
  });

  return <String, dynamic>{
    'type': 'response.create',
    if (response.isNotEmpty) 'response': response,
  };
}

Future<ModelResponse> _consumeRealtimeResponse(
  StreamIterator<dynamic> iterator,
  ActionFnArg<ModelResponseChunk, ModelRequest, ModelRequest> ctx,
  bool jsonMode,
) async {
  final textBuffer = StringBuffer();
  final content = <Part>[];
  final emittedToolRefs = <String>{};

  while (await iterator.moveNext()) {
    final event = _decodeRealtimeEvent(iterator.current);
    if (event == null) continue;
    final type = event['type'] as String?;
    if (type == null) continue;

    if (type == 'error') {
      final error = _asJsonMap(event['error']) ?? const <String, dynamic>{};
      throw GenkitException(
        error['message'] as String? ?? 'Realtime API error',
        status: StatusCodes.UNKNOWN,
        details: jsonEncode(error),
      );
    }

    if (type == 'response.text.delta' || type == 'response.output_text.delta') {
      final delta = event['delta'];
      if (delta is String && delta.isNotEmpty) {
        textBuffer.write(delta);
        if (ctx.streamingRequested) {
          ctx.sendChunk(
            ModelResponseChunk(content: <Part>[TextPart(text: delta)]),
          );
        }
      }
      continue;
    }

    if (type == 'response.function_call_arguments.done') {
      final toolPart = _toolRequestFromRealtimeFunctionCall(event, jsonMode);
      if (toolPart != null) {
        final ref = toolPart.toolRequest.ref;
        if (ref == null || ref.isEmpty || emittedToolRefs.add(ref)) {
          content.add(toolPart);
          if (ctx.streamingRequested) {
            ctx.sendChunk(ModelResponseChunk(content: <Part>[toolPart]));
          }
        }
      }
      continue;
    }

    if (type != 'response.done') {
      continue;
    }

    final response = _asJsonMap(event['response']) ?? const <String, dynamic>{};
    final finishReason = _finishReasonFromRealtimeResponse(response);
    final parsedContent = _partsFromRealtimeResponseOutput(
      response,
      emittedToolRefs,
      jsonMode,
    );
    if (parsedContent.isNotEmpty) {
      content.addAll(parsedContent);
    } else if (textBuffer.isNotEmpty) {
      content.add(TextPart(text: textBuffer.toString()));
    }
    if (ctx.streamingRequested) {
      ctx.sendChunk(
        ModelResponseChunk(
          content: const <Part>[],
          custom: <String, dynamic>{
            'realtime': <String, dynamic>{
              'type': 'response.done',
              'finishReason': finishReason.value,
            },
          },
        ),
      );
    }

    return ModelResponse(
      finishReason: finishReason,
      finishMessage: _finishMessageFromRealtimeResponse(response),
      message: Message(role: Role.model, content: content),
      usage: _usageFromRealtimeResponse(response),
      raw: <String, dynamic>{'event': event},
    );
  }

  throw GenkitException(
    'Realtime socket closed before response completion.',
    status: StatusCodes.UNAVAILABLE,
  );
}

Map<String, dynamic>? _decodeRealtimeEvent(dynamic raw) {
  try {
    if (raw is String) {
      final decoded = jsonDecode(raw);
      return _asJsonMap(decoded);
    }
    if (raw is List<int>) {
      final decoded = jsonDecode(utf8.decode(raw));
      return _asJsonMap(decoded);
    }
    return _asJsonMap(raw);
  } catch (_) {
    return null;
  }
}

List<Part> _partsFromRealtimeResponseOutput(
  Map<String, dynamic> response,
  Set<String> emittedToolRefs,
  bool jsonMode,
) {
  final output = response['output'];
  if (output is! List) return const <Part>[];

  final parts = <Part>[];
  for (final rawItem in output.whereType<Map>()) {
    final item = Map<String, dynamic>.from(rawItem);
    final type = item['type'] as String?;
    if (type == 'function_call') {
      final toolPart = _toolRequestFromRealtimeFunctionCall(item, jsonMode);
      if (toolPart == null) continue;
      final ref = toolPart.toolRequest.ref;
      if (ref == null || ref.isEmpty || emittedToolRefs.add(ref)) {
        parts.add(toolPart);
      }
      continue;
    }
    if (type != 'message') continue;

    final content = item['content'];
    if (content is! List) continue;
    for (final rawContentPart in content.whereType<Map>()) {
      final contentPart = Map<String, dynamic>.from(rawContentPart);
      final contentType = contentPart['type'] as String?;
      if (contentType == 'output_text' || contentType == 'text') {
        final text = contentPart['text'];
        if (text is String && text.isNotEmpty) {
          parts.add(jsonMode ? _toJsonOrTextPart(text) : TextPart(text: text));
        }
      }
    }
  }
  return parts;
}

Part _toJsonOrTextPart(String text) {
  try {
    final decoded = jsonDecode(text);
    if (decoded is Map<String, dynamic>) {
      return DataPart(data: decoded);
    }
    if (decoded is Map) {
      return DataPart(data: Map<String, dynamic>.from(decoded));
    }
    return DataPart(data: <String, dynamic>{'value': decoded});
  } catch (_) {
    return TextPart(text: text);
  }
}

ToolRequestPart? _toolRequestFromRealtimeFunctionCall(
  Map<String, dynamic> data,
  bool jsonMode,
) {
  final name = data['name'] as String?;
  if (name == null || name.isEmpty) return null;
  final callId = data['call_id'] as String?;
  final rawArguments = data['arguments'];

  Map<String, dynamic>? parsedInput;
  if (rawArguments is String && rawArguments.isNotEmpty) {
    try {
      final decoded = jsonDecode(rawArguments);
      if (decoded is Map<String, dynamic>) {
        parsedInput = decoded;
      } else if (decoded is Map) {
        parsedInput = Map<String, dynamic>.from(decoded);
      } else if (jsonMode) {
        parsedInput = <String, dynamic>{'value': decoded};
      }
    } catch (_) {
      // Keep null to mirror chat-completions behavior when args are malformed.
    }
  }

  return ToolRequestPart(
    toolRequest: ToolRequest(name: name, ref: callId, input: parsedInput),
  );
}

GenerationUsage? _usageFromRealtimeResponse(Map<String, dynamic> response) {
  final usage = _asJsonMap(response['usage']);
  if (usage == null) return null;
  return GenerationUsage(
    inputTokens: (usage['input_tokens'] as num?)?.toDouble(),
    outputTokens: (usage['output_tokens'] as num?)?.toDouble(),
    totalTokens: (usage['total_tokens'] as num?)?.toDouble(),
  );
}

FinishReason _finishReasonFromRealtimeResponse(Map<String, dynamic> response) {
  final status = response['status'] as String?;
  switch (status) {
    case 'completed':
      return FinishReason.stop;
    case 'incomplete':
      return FinishReason.length;
    case 'cancelled':
      return FinishReason.interrupted;
    case 'failed':
      return FinishReason.other;
    default:
      return FinishReason.unknown;
  }
}

String? _finishMessageFromRealtimeResponse(Map<String, dynamic> response) {
  final statusDetails = _asJsonMap(response['status_details']);
  if (statusDetails == null) return null;
  final reason = statusDetails['reason'];
  if (reason is String && reason.isNotEmpty) {
    return reason;
  }
  final error = _asJsonMap(statusDetails['error']);
  final message = error?['message'];
  if (message is String && message.isNotEmpty) {
    return message;
  }
  return null;
}

StatusCodes _statusFromRealtimeException(OpenAIHttpException e) {
  switch (e.statusCode) {
    case 429:
      return StatusCodes.RESOURCE_EXHAUSTED;
    case 401:
      return StatusCodes.PERMISSION_DENIED;
    case 403:
      return StatusCodes.UNAUTHENTICATED;
    case 400:
      return StatusCodes.INVALID_ARGUMENT;
    case 404:
      return StatusCodes.NOT_FOUND;
    case 500:
      return StatusCodes.INTERNAL;
    case 503:
      return StatusCodes.UNAVAILABLE;
    default:
      return StatusCodes.UNKNOWN;
  }
}

Map<String, dynamic>? _asJsonMap(Object? value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  return null;
}

void _sendRealtimeEvent(WebSocket socket, Map<String, dynamic> event) {
  socket.add(jsonEncode(event));
}
