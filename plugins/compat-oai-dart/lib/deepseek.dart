import 'package:genkit/plugin.dart';

import 'genkit_compat_oai.dart';

typedef DeepSeekPluginOptions = ({
  String? apiKey,
  Map<String, String>? headers,
  Duration? timeout,
});

final ModelInfo _deepSeekModelInfo = ModelInfo(
  supports: <String, dynamic>{
    'multiturn': true,
    'tools': true,
    'media': false,
    'systemRole': true,
    'output': <String>['text', 'json'],
  },
);

void deepSeekRequestBuilder(ModelRequest req, Map<String, dynamic> params) {
  final maxTokens = req.config?['maxTokens'];
  if (maxTokens != null) {
    params['max_tokens'] = maxTokens;
  }
}

ModelRef<Map<String, dynamic>> deepSeekModelRef(String name, {String? config}) {
  return compatOaiModelRef(name: name, namespace: 'deepseek');
}

final Map<String, ModelInfo> supportedDeepSeekModels = <String, ModelInfo>{
  'deepseek-reasoner': _deepSeekModelInfo,
  'deepseek-chat': _deepSeekModelInfo,
};

GenkitPlugin deepSeekPlugin({
  String? apiKey,
  Map<String, String>? headers,
  Duration? timeout,
}) {
  final key = apiKey ?? getConfigVar('DEEPSEEK_API_KEY');
  if (key == null || key.isEmpty) {
    throw GenkitException(
      'Please pass in the API key or set the DEEPSEEK_API_KEY environment variable.',
      status: StatusCodes.FAILED_PRECONDITION,
    );
  }
  final baseOptions = PluginOptions(
    name: 'deepseek',
    apiKey: key,
    baseUrl: 'https://api.deepseek.com',
    headers: headers,
    timeout: timeout,
  );
  late final PluginOptions pluginOptions;
  pluginOptions = baseOptions.copyWith(
    initializer: (client) async {
      return supportedDeepSeekModels.entries
          .map(
            (entry) => defineCompatOpenAIModel(
              name: entry.key,
              client: client,
              pluginOptions: pluginOptions,
              modelRef: deepSeekModelRef(entry.key),
              info: entry.value,
              requestBuilder: deepSeekRequestBuilder,
            ),
          )
          .toList();
    },
    resolver: (client, actionType, actionName) {
      if (actionType != 'model') return null;
      return defineCompatOpenAIModel(
        name: actionName,
        client: client,
        pluginOptions: pluginOptions,
        modelRef: deepSeekModelRef(actionName),
        info: supportedDeepSeekModels[actionName] ?? _deepSeekModelInfo,
        requestBuilder: deepSeekRequestBuilder,
      );
    },
    listActions: (client) async {
      final models = await client.listModels();
      return models.where((model) => model['object'] == 'model').map((model) {
        final id = model['id'] as String? ?? '';
        final info = supportedDeepSeekModels[id] ?? _deepSeekModelInfo;
        return modelMetadata('deepseek/$id', modelInfo: info);
      }).toList();
    },
  );
  return openAICompatible(pluginOptions);
}

class DeepSeekPluginHandle {
  const DeepSeekPluginHandle();

  GenkitPlugin call({
    String? apiKey,
    Map<String, String>? headers,
    Duration? timeout,
  }) {
    return deepSeekPlugin(apiKey: apiKey, headers: headers, timeout: timeout);
  }

  ModelRef<Map<String, dynamic>> model(String name) {
    return deepSeekModelRef(name);
  }
}

const DeepSeekPluginHandle deepSeek = DeepSeekPluginHandle();
