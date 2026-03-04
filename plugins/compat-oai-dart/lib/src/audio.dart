import 'dart:convert';
import 'dart:typed_data';

import 'package:genkit/genkit.dart';
import 'package:genkit/plugin.dart';

import 'client.dart';
import 'options.dart';
import 'utils.dart';

typedef SpeechRequestBuilder =
    void Function(ModelRequest req, Map<String, dynamic> params);
typedef TranscriptionRequestBuilder =
    void Function(ModelRequest req, Map<String, dynamic> params);

final ModelInfo transcriptionModelInfo = ModelInfo(
  supports: <String, dynamic>{
    'media': true,
    'output': <String>['text', 'json'],
    'multiturn': false,
    'systemRole': false,
    'tools': false,
  },
);

final ModelInfo speechModelInfo = ModelInfo(
  supports: <String, dynamic>{
    'media': false,
    'output': <String>['media'],
    'multiturn': false,
    'systemRole': false,
    'tools': false,
  },
);

const Map<String, String> responseFormatMediaTypes = <String, String>{
  'mp3': 'audio/mpeg',
  'opus': 'audio/opus',
  'aac': 'audio/aac',
  'flac': 'audio/flac',
  'wav': 'audio/wav',
  'pcm': 'audio/L16',
};

Map<String, dynamic> toTTSRequest(
  String modelName,
  ModelRequest request, {
  SpeechRequestBuilder? requestBuilder,
}) {
  final config = Map<String, dynamic>.from(request.config ?? const {});
  final voice = config.remove('voice');
  final modelVersion = config.remove('version');
  config.remove('temperature');
  config.remove('maxOutputTokens');
  config.remove('stopSequences');
  config.remove('topK');
  config.remove('topP');

  final options = <String, dynamic>{
    'model': modelVersion ?? modelName,
    'input': request.messages.first.text,
    'voice': voice ?? 'alloy',
  };
  if (requestBuilder != null) {
    requestBuilder(request, options);
  } else {
    options.addAll(config);
  }
  options.removeWhere((_, value) => value == null);
  return options;
}

ModelResponse speechToGenerateResponse(
  Uint8List responseBytes, {
  String responseFormat = 'mp3',
}) {
  final mediaType = responseFormatMediaTypes[responseFormat] ?? 'audio/mpeg';
  final encoded = base64Encode(responseBytes);
  return ModelResponse(
    finishReason: FinishReason.stop,
    message: Message(
      role: Role.model,
      content: <Part>[
        MediaPart(
          media: Media(
            contentType: mediaType,
            url: 'data:$mediaType;base64,$encoded',
          ),
        ),
      ],
    ),
  );
}

({CompatUploadFile file, String prompt, Map<String, dynamic> config})
_audioUploadFromRequest(ModelRequest request) {
  final message = request.messages.first;
  final media = message.media;
  if (media == null || media.url.isEmpty) {
    throw StateError('No media found in the request');
  }
  if (!media.url.startsWith('data:')) {
    throw StateError('Only base64 data URLs are supported for audio input.');
  }
  final match = RegExp(r'^data:([^;]+);base64,(.+)$').firstMatch(media.url);
  if (match == null) {
    throw StateError('No media found in the request');
  }

  final contentType = media.contentType ?? match.group(1)!;
  final bytes = base64Decode(match.group(2)!);
  final file = CompatUploadFile(
    filename: 'input',
    contentType: contentType,
    bytes: bytes,
  );
  return (
    file: file,
    prompt: message.text,
    config: Map<String, dynamic>.from(request.config ?? const {}),
  );
}

Map<String, dynamic> toSttRequest(
  String modelName,
  ModelRequest request, {
  TranscriptionRequestBuilder? requestBuilder,
}) {
  final upload = _audioUploadFromRequest(request);
  final config = upload.config;
  final temperature = config.remove('temperature');
  final modelVersion = config.remove('version');
  config.remove('maxOutputTokens');
  config.remove('stopSequences');
  config.remove('topK');
  config.remove('topP');

  final options = <String, dynamic>{
    'model': modelVersion ?? modelName,
    'file': upload.file,
    'prompt': upload.prompt,
    'temperature': temperature,
  };
  if (requestBuilder != null) {
    requestBuilder(request, options);
  } else {
    options.addAll(config);
  }

  final outputFormat = request.output?.format;
  final customFormat = (request.config ?? const {})['response_format'];
  if (outputFormat != null && customFormat != null) {
    if (outputFormat == 'json' &&
        customFormat != 'json' &&
        customFormat != 'verbose_json') {
      throw StateError(
        'Custom response format $customFormat is not compatible with output format $outputFormat',
      );
    }
  }
  if (outputFormat == 'media') {
    throw StateError('Output format $outputFormat is not supported.');
  }
  options['response_format'] = customFormat ?? outputFormat ?? 'text';
  options.removeWhere((_, value) => value == null);
  return options;
}

ModelResponse transcriptionToGenerateResponse(dynamic result) {
  final text = result is String
      ? result
      : (result is Map ? (result['text'] as String? ?? '') : '');
  return ModelResponse(
    finishReason: FinishReason.stop,
    message: Message(
      role: Role.model,
      content: <Part>[TextPart(text: text)],
    ),
    raw: result is Map ? Map<String, dynamic>.from(result) : null,
  );
}

Model defineCompatOpenAISpeechModel({
  required String name,
  required CompatOpenAIClient client,
  required PluginOptions pluginOptions,
  ModelRef<Map<String, dynamic>>? modelRef,
  ModelInfo? info,
  SpeechRequestBuilder? requestBuilder,
}) {
  final modelName = toModelName(name, pluginOptions.name);
  final actionName = modelRef?.name ?? '${pluginOptions.name}/$modelName';

  return Model(
    name: actionName,
    metadata: Map<String, dynamic>.from(
      modelMetadata(actionName, modelInfo: info ?? speechModelInfo).metadata,
    ),
    fn: (request, _) async {
      if (request == null) {
        throw GenkitException(
          'Model request is required.',
          status: StatusCodes.INVALID_ARGUMENT,
        );
      }
      final ttsRequest = toTTSRequest(
        modelName,
        request,
        requestBuilder: requestBuilder,
      );
      final scoped = maybeCreateRequestScopedOpenAIClient(
        pluginOptions,
        request,
        client,
      );
      final bytes = await scoped.createSpeech(ttsRequest);
      return speechToGenerateResponse(
        bytes,
        responseFormat: (ttsRequest['response_format'] as String?) ?? 'mp3',
      );
    },
  );
}

ModelRef<Map<String, dynamic>> compatOaiSpeechModelRef({
  required String name,
  String? namespace,
}) {
  final namespaced = namespace == null || name.startsWith('$namespace/')
      ? name
      : '$namespace/$name';
  return modelRef(namespaced);
}

Model defineCompatOpenAITranscriptionModel({
  required String name,
  required CompatOpenAIClient client,
  PluginOptions? pluginOptions,
  ModelRef<Map<String, dynamic>>? modelRef,
  ModelInfo? info,
  TranscriptionRequestBuilder? requestBuilder,
}) {
  final modelName = toModelName(name, pluginOptions?.name);
  final actionName =
      modelRef?.name ?? '${pluginOptions?.name ?? 'compat-oai'}/$modelName';

  return Model(
    name: actionName,
    metadata: Map<String, dynamic>.from(
      modelMetadata(
        actionName,
        modelInfo: info ?? transcriptionModelInfo,
      ).metadata,
    ),
    fn: (request, _) async {
      if (request == null) {
        throw GenkitException(
          'Model request is required.',
          status: StatusCodes.INVALID_ARGUMENT,
        );
      }
      final params = toSttRequest(
        modelName,
        request,
        requestBuilder: requestBuilder,
      );
      final scoped = maybeCreateRequestScopedOpenAIClient(
        pluginOptions,
        request,
        client,
      );
      final file = params.remove('file') as CompatUploadFile;
      final result = await scoped.createTranscription(
        fields: <String, dynamic>{...params, 'stream': false},
        file: file,
      );
      return transcriptionToGenerateResponse(result);
    },
  );
}

ModelRef<Map<String, dynamic>> compatOaiTranscriptionModelRef({
  required String name,
  String? namespace,
}) {
  final namespaced = namespace == null || name.startsWith('$namespace/')
      ? name
      : '$namespace/$name';
  return modelRef(namespaced);
}
