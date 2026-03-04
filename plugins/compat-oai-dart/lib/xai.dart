import 'package:genkit/plugin.dart';

import 'genkit_compat_oai.dart';

final ModelInfo _xaiLanguageModelInfo = ModelInfo(
  supports: <String, dynamic>{
    'multiturn': true,
    'tools': true,
    'media': false,
    'systemRole': true,
    'output': <String>['text', 'json'],
  },
);

void grokRequestBuilder(ModelRequest req, Map<String, dynamic> params) {
  final config = req.config ?? const <String, dynamic>{};
  params['web_search_options'] = config['webSearchOptions'];
  params['reasoning_effort'] = config['reasoningEffort'];
  params['deferred'] = config['deferred'];
}

ModelRef<Map<String, dynamic>> xaiModelRef(String name) {
  return compatOaiModelRef(name: name, namespace: 'xai');
}

ModelRef<Map<String, dynamic>> xaiImageModelRef(String name) {
  return compatOaiImageModelRef(name: name, namespace: 'xai');
}

final Map<String, ModelInfo> supportedXaiLanguageModels = <String, ModelInfo>{
  'grok-3': _xaiLanguageModelInfo,
  'grok-3-fast': _xaiLanguageModelInfo,
  'grok-3-mini': _xaiLanguageModelInfo,
  'grok-3-mini-fast': _xaiLanguageModelInfo,
  'grok-2-vision-1212': ModelInfo(
    supports: <String, dynamic>{
      'multiturn': false,
      'tools': true,
      'media': true,
      'systemRole': false,
      'output': <String>['text', 'json'],
    },
  ),
};

final Map<String, ModelInfo> supportedXaiImageModels = <String, ModelInfo>{
  'grok-2-image-1212': imageGenerationModelInfo,
};

GenkitPlugin xAIPlugin({
  String? apiKey,
  Map<String, String>? headers,
  Duration? timeout,
}) {
  final key = apiKey ?? getConfigVar('XAI_API_KEY');
  if (key == null || key.isEmpty) {
    throw GenkitException(
      'Please pass in the API key or set the XAI_API_KEY environment variable.',
      status: StatusCodes.FAILED_PRECONDITION,
    );
  }

  final baseOptions = PluginOptions(
    name: 'xai',
    apiKey: key,
    baseUrl: 'https://api.x.ai/v1',
    headers: headers,
    timeout: timeout,
  );
  late final PluginOptions pluginOptions;
  pluginOptions = baseOptions.copyWith(
    initializer: (client) async {
      final actions = <Action>[];
      actions.addAll(
        supportedXaiLanguageModels.entries.map(
          (entry) => defineCompatOpenAIModel(
            name: entry.key,
            client: client,
            pluginOptions: pluginOptions,
            modelRef: xaiModelRef(entry.key),
            info: entry.value,
            requestBuilder: grokRequestBuilder,
          ),
        ),
      );
      actions.addAll(
        supportedXaiImageModels.entries.map(
          (entry) => defineCompatOpenAIImageModel(
            name: entry.key,
            client: client,
            pluginOptions: pluginOptions,
            modelRef: xaiImageModelRef(entry.key),
            info: entry.value,
          ),
        ),
      );
      return actions;
    },
    resolver: (client, actionType, actionName) {
      if (actionType != 'model') return null;
      if (actionName.contains('image')) {
        return defineCompatOpenAIImageModel(
          name: actionName,
          client: client,
          pluginOptions: pluginOptions,
          modelRef: xaiImageModelRef(actionName),
          info: supportedXaiImageModels[actionName] ?? imageGenerationModelInfo,
        );
      }
      return defineCompatOpenAIModel(
        name: actionName,
        client: client,
        pluginOptions: pluginOptions,
        modelRef: xaiModelRef(actionName),
        info: supportedXaiLanguageModels[actionName] ?? _xaiLanguageModelInfo,
        requestBuilder: grokRequestBuilder,
      );
    },
    listActions: (client) async {
      final models = await client.listModels();
      return models.where((model) => model['object'] == 'model').map((model) {
        final id = model['id'] as String? ?? '';
        if (id.contains('image')) {
          return modelMetadata(
            'xai/$id',
            modelInfo: supportedXaiImageModels[id] ?? imageGenerationModelInfo,
          );
        }
        return modelMetadata(
          'xai/$id',
          modelInfo: supportedXaiLanguageModels[id] ?? _xaiLanguageModelInfo,
        );
      }).toList();
    },
  );

  return openAICompatible(pluginOptions);
}

class XAIPluginHandle {
  const XAIPluginHandle();

  GenkitPlugin call({
    String? apiKey,
    Map<String, String>? headers,
    Duration? timeout,
  }) {
    return xAIPlugin(apiKey: apiKey, headers: headers, timeout: timeout);
  }

  ModelRef<Map<String, dynamic>> model(String name) {
    if (name.contains('image')) {
      return xaiImageModelRef(name);
    }
    return xaiModelRef(name);
  }
}

const XAIPluginHandle xAI = XAIPluginHandle();
