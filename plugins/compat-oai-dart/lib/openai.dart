import 'package:genkit/plugin.dart';

import 'genkit_compat_oai.dart';

const String _openAINamespace = 'openai';

class CustomModelDefinition {
  final String name;
  final ModelInfo? info;

  const CustomModelDefinition({required this.name, this.info});
}

const List<String> _unsupportedModelMatchers = <String>[
  'babbage',
  'davinci',
  'codex',
];

bool _isOpenAIImageModelName(String modelName) {
  final normalized = modelName.toLowerCase();
  return normalized.contains('gpt-image') ||
      normalized.contains('chatgpt-image') ||
      normalized.contains('dall-e');
}

bool _isOpenAIVideoModelName(String modelName) {
  final normalized = modelName.toLowerCase();
  return normalized.contains('sora-');
}

bool _isEmbeddingModelName(String modelName) {
  return modelName.toLowerCase().contains('embedding');
}

bool _isSpeechModelName(String modelName) {
  return modelName.toLowerCase().contains('tts');
}

bool _isWhisperModelName(String modelName) {
  return modelName.toLowerCase().contains('whisper');
}

bool _isTranscriptionModelName(String modelName) {
  return modelName.toLowerCase().contains('transcribe');
}

bool _isUnsupportedModelName(String modelName) {
  return _unsupportedModelMatchers.any(modelName.contains);
}

String _normalizeOpenAIName(String name) {
  return toModelName(name, _openAINamespace);
}

bool _needsGptImageRequestBuilder(String modelName) {
  final normalized = modelName.toLowerCase();
  return normalized.contains('gpt-image') ||
      normalized.contains('chatgpt-image');
}

String _actionTypeForListedModel(String modelName) {
  final normalized = _normalizeOpenAIName(modelName);
  if (_isEmbeddingModelName(normalized)) {
    return 'embedder';
  }
  if (isRealtimeModelName(normalized)) {
    return 'bidi-model';
  }
  return 'model';
}

ActionMetadata<dynamic, dynamic, dynamic, dynamic> _bidiModelMetadata(
  String name, {
  required ModelInfo modelInfo,
}) {
  final metadata = modelMetadata(name, modelInfo: modelInfo);
  return ActionMetadata<dynamic, dynamic, dynamic, dynamic>(
    name: name,
    description: metadata.description,
    actionType: 'bidi-model',
    metadata: Map<String, dynamic>.from(metadata.metadata),
  );
}

ModelRef<Map<String, dynamic>> openAIModelRef(String name) {
  return compatOaiModelRef(
    name: _normalizeOpenAIName(name),
    namespace: _openAINamespace,
  );
}

ModelRef<Map<String, dynamic>> openAIImageModelRef(String name) {
  return compatOaiImageModelRef(
    name: _normalizeOpenAIName(name),
    namespace: _openAINamespace,
  );
}

ModelRef<Map<String, dynamic>> openAIVideoModelRef(String name) {
  return compatOaiVideoModelRef(
    name: _normalizeOpenAIName(name),
    namespace: _openAINamespace,
  );
}

ModelRef<Map<String, dynamic>> openAISpeechModelRef(String name) {
  return compatOaiSpeechModelRef(
    name: _normalizeOpenAIName(name),
    namespace: _openAINamespace,
  );
}

ModelRef<Map<String, dynamic>> openAITranscriptionModelRef(String name) {
  return compatOaiTranscriptionModelRef(
    name: _normalizeOpenAIName(name),
    namespace: _openAINamespace,
  );
}

ModelRef<Map<String, dynamic>> openAIWhisperModelRef(String name) {
  return compatOaiTranscriptionModelRef(
    name: _normalizeOpenAIName(name),
    namespace: _openAINamespace,
  );
}

EmbedderRef<Map<String, dynamic>> openAIEmbedderRef(String name) {
  final normalizedName = _normalizeOpenAIName(name);
  return embedderRef('$_openAINamespace/$normalizedName');
}

void gptImage1RequestBuilder(ModelRequest req, Map<String, dynamic> params) {
  final config = req.config ?? const <String, dynamic>{};
  params['response_format'] = null;
  params['background'] = config['background'];
  params['moderation'] = config['moderation'];
  params['n'] = config['n'];
  params['output_compression'] = config['output_compression'];
  params['output_format'] = config['output_format'];
  params['quality'] = config['quality'];
  params['style'] = config['style'];
  params['user'] = config['user'];
}

Model _defineOpenAIWhisperModel({
  required String name,
  required CompatOpenAIClient client,
  PluginOptions? pluginOptions,
  ModelRef<Map<String, dynamic>>? modelRef,
  ModelInfo? info,
}) {
  final modelName = toModelName(name, pluginOptions?.name);
  final actionName =
      modelRef?.name ?? '${pluginOptions?.name ?? 'openai'}/$modelName';
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
      final cleanConfig = Map<String, dynamic>.from(request.config ?? const {})
        ..remove('translate');
      final cleanRequest = ModelRequest(
        messages: request.messages,
        config: cleanConfig,
        tools: request.tools,
        toolChoice: request.toolChoice,
        output: request.output,
        docs: request.docs,
      );
      final scoped = maybeCreateRequestScopedOpenAIClient(
        pluginOptions,
        request,
        client,
      );
      final translate = request.config?['translate'] == true;
      if (translate) {
        final params = toTranslationRequest(modelName, cleanRequest);
        final file = params.remove('file') as CompatUploadFile;
        final result = await scoped.createTranslation(
          fields: params,
          file: file,
        );
        return translationToGenerateResponse(result);
      }
      final params = toSttRequest(modelName, cleanRequest);
      final file = params.remove('file') as CompatUploadFile;
      final result = await scoped.createTranscription(
        fields: <String, dynamic>{...params, 'stream': false},
        file: file,
      );
      return transcriptionToGenerateResponse(result);
    },
  );
}

Action? _resolveAction({
  required CompatOpenAIClient client,
  required PluginOptions pluginOptions,
  required String actionType,
  required String actionName,
  ModelInfo? info,
}) {
  final normalizedActionName = _normalizeOpenAIName(actionName);
  if (actionType == 'embedder') {
    return defineCompatOpenAIEmbedder(
      name: normalizedActionName,
      client: client,
      pluginOptions: pluginOptions,
    );
  }

  if (actionType == 'bidi-model') {
    if (!isRealtimeModelName(normalizedActionName)) return null;
    return defineCompatOpenAIRealtimeModel(
      name: normalizedActionName,
      client: client,
      pluginOptions: pluginOptions,
      info: info ?? realtimeModelInfo,
    );
  }

  if (actionType != 'model') return null;
  if (_isOpenAIVideoModelName(normalizedActionName)) {
    return defineCompatOpenAIVideoModel(
      name: normalizedActionName,
      client: client,
      pluginOptions: pluginOptions,
      info: info ?? videoGenerationModelInfo,
    );
  }
  if (_isOpenAIImageModelName(normalizedActionName)) {
    return defineCompatOpenAIImageModel(
      name: normalizedActionName,
      client: client,
      pluginOptions: pluginOptions,
      info: info ?? imageGenerationModelInfo,
      requestBuilder: _needsGptImageRequestBuilder(normalizedActionName)
          ? gptImage1RequestBuilder
          : null,
    );
  }
  if (_isSpeechModelName(normalizedActionName)) {
    return defineCompatOpenAISpeechModel(
      name: normalizedActionName,
      client: client,
      pluginOptions: pluginOptions,
      info: info ?? speechModelInfo,
    );
  }
  if (_isWhisperModelName(normalizedActionName)) {
    return _defineOpenAIWhisperModel(
      name: normalizedActionName,
      client: client,
      pluginOptions: pluginOptions,
      info: info ?? transcriptionModelInfo,
    );
  }
  if (_isTranscriptionModelName(normalizedActionName)) {
    return defineCompatOpenAITranscriptionModel(
      name: normalizedActionName,
      client: client,
      pluginOptions: pluginOptions,
      info: info ?? transcriptionModelInfo,
    );
  }
  return defineCompatOpenAIModel(
    name: normalizedActionName,
    client: client,
    pluginOptions: pluginOptions,
    info: info ?? genericModelInfo,
  );
}

ActionMetadata<dynamic, dynamic, dynamic, dynamic> _toActionMetadata(
  String modelName,
) {
  final normalizedModelName = _normalizeOpenAIName(modelName);
  if (_isEmbeddingModelName(normalizedModelName)) {
    return embedderMetadata(openAIEmbedderRef(normalizedModelName).name);
  }
  if (isRealtimeModelName(normalizedModelName)) {
    return _bidiModelMetadata(
      openAIModelRef(normalizedModelName).name,
      modelInfo: realtimeModelInfo,
    );
  }
  if (_isOpenAIImageModelName(normalizedModelName)) {
    return modelMetadata(
      openAIImageModelRef(normalizedModelName).name,
      modelInfo: imageGenerationModelInfo,
    );
  }
  if (_isOpenAIVideoModelName(normalizedModelName)) {
    return modelMetadata(
      openAIVideoModelRef(normalizedModelName).name,
      modelInfo: videoGenerationModelInfo,
    );
  }
  if (_isSpeechModelName(normalizedModelName)) {
    return modelMetadata(
      openAISpeechModelRef(normalizedModelName).name,
      modelInfo: speechModelInfo,
    );
  }
  if (_isWhisperModelName(normalizedModelName) ||
      _isTranscriptionModelName(normalizedModelName)) {
    final ref = _isWhisperModelName(normalizedModelName)
        ? openAIWhisperModelRef(normalizedModelName)
        : openAITranscriptionModelRef(normalizedModelName);
    return modelMetadata(ref.name, modelInfo: transcriptionModelInfo);
  }
  return modelMetadata(
    openAIModelRef(normalizedModelName).name,
    modelInfo: genericModelInfo,
  );
}

Iterable<String> _extractListedModelNames(List<Map<String, dynamic>> models) {
  return models
      .map((model) => (model['id'] as String? ?? '').trim())
      .where((id) => id.isNotEmpty)
      .where((id) => !_isUnsupportedModelName(id));
}

GenkitPlugin openAIPlugin({
  String? apiKey,
  String? baseUrl,
  List<CustomModelDefinition>? models,
  Map<String, String>? headers,
  Duration? timeout,
}) {
  final pluginOptions = PluginOptions(
    name: _openAINamespace,
    apiKey: apiKey ?? getConfigVar('OPENAI_API_KEY'),
    baseUrl: baseUrl,
    headers: headers,
    timeout: timeout,
  );

  final optionsWithCallbacks = pluginOptions.copyWith(
    initializer: (client) async {
      final actionsByName = <String, Action>{};
      final listedModels = await client.listModels();
      for (final modelName in _extractListedModelNames(listedModels)) {
        final action = _resolveAction(
          client: client,
          pluginOptions: pluginOptions,
          actionType: _actionTypeForListedModel(modelName),
          actionName: modelName,
        );
        if (action != null) {
          actionsByName[action.name] = action;
        }
      }

      if (models != null) {
        for (final model in models) {
          final action = _resolveAction(
            client: client,
            pluginOptions: pluginOptions,
            actionType: isRealtimeModelName(model.name)
                ? 'bidi-model'
                : 'model',
            actionName: model.name,
            info: model.info,
          );
          if (action != null) {
            actionsByName[action.name] = action;
          }
        }
      }
      return actionsByName.values.toList();
    },
    resolver: (client, actionType, actionName) {
      return _resolveAction(
        client: client,
        pluginOptions: pluginOptions,
        actionType: actionType,
        actionName: actionName,
      );
    },
    listActions: (client) async {
      final models = await client.listModels();
      return _extractListedModelNames(models).map(_toActionMetadata).toList();
    },
  );

  return openAICompatible(optionsWithCallbacks);
}

class OpenAIPluginHandle {
  const OpenAIPluginHandle();

  GenkitPlugin call({
    String? apiKey,
    String? baseUrl,
    List<CustomModelDefinition>? models,
    Map<String, String>? headers,
    Duration? timeout,
  }) {
    return openAIPlugin(
      apiKey: apiKey,
      baseUrl: baseUrl,
      models: models,
      headers: headers,
      timeout: timeout,
    );
  }

  ModelRef<Map<String, dynamic>> model(String name) {
    final normalizedName = _normalizeOpenAIName(name);
    if (_isOpenAIVideoModelName(normalizedName)) {
      return openAIVideoModelRef(normalizedName);
    }
    if (_isOpenAIImageModelName(normalizedName)) {
      return openAIImageModelRef(normalizedName);
    }
    if (_isSpeechModelName(normalizedName)) {
      return openAISpeechModelRef(normalizedName);
    }
    if (_isWhisperModelName(normalizedName)) {
      return openAIWhisperModelRef(normalizedName);
    }
    if (_isTranscriptionModelName(normalizedName)) {
      return openAITranscriptionModelRef(normalizedName);
    }
    return openAIModelRef(normalizedName);
  }

  EmbedderRef<Map<String, dynamic>> embedder(String name) {
    return openAIEmbedderRef(_normalizeOpenAIName(name));
  }
}

const OpenAIPluginHandle openAI = OpenAIPluginHandle();
