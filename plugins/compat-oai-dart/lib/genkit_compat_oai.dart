library;

import 'package:genkit/plugin.dart';

import 'src/client.dart';
import 'src/model.dart';
import 'src/options.dart';
import 'src/realtime.dart';
import 'src/utils.dart';

export 'src/audio.dart';
export 'src/client.dart'
    show CompatOpenAIClient, CompatUploadFile, OpenAIHttpException;
export 'src/embedder.dart';
export 'src/image.dart';
export 'src/model.dart';
export 'src/options.dart' show PluginOptions;
export 'src/realtime.dart';
export 'src/translate.dart';
export 'src/utils.dart';
export 'src/video.dart';

export 'deepseek.dart';
export 'openai.dart';
export 'xai.dart';

class OpenAICompatiblePlugin extends GenkitPlugin {
  @override
  final String name;

  final PluginOptions _options;
  CompatOpenAIClient? _client;
  List<ActionMetadata<dynamic, dynamic, dynamic, dynamic>>? _listActionsCache;

  OpenAICompatiblePlugin(this._options) : name = _options.name;

  CompatOpenAIClient _createClient() {
    final existing = _client;
    if (existing != null) return existing;
    final client = CompatOpenAIClient(
      apiKey: _options.apiKeyDisabled
          ? 'placeholder'
          : (_options.apiKeyOrNull ?? ''),
      baseUrl: _options.baseUrl ?? 'https://api.openai.com/v1',
      headers: _options.headers ?? const <String, String>{},
      timeout: _options.timeout,
    );
    _client = client;
    return client;
  }

  @override
  Future<List<Action>> init() async {
    if (_options.initializer == null) {
      return const <Action>[];
    }
    final actions = await _options.initializer!(_createClient());
    return actions;
  }

  @override
  Action? resolve(String actionType, String actionName) {
    final resolver = _options.resolver;
    if (resolver != null) {
      final result = resolver(_createClient(), actionType, actionName);
      if (result is Action?) {
        return result;
      }
      // Async resolve is not supported by GenkitPlugin.resolve API.
      throw GenkitException(
        'Async resolver is not supported by the current Genkit Dart plugin API.',
        status: StatusCodes.UNIMPLEMENTED,
      );
    }

    if (actionType == 'model') {
      return defineCompatOpenAIModel(
        name: toModelName(actionName, _options.name),
        client: _createClient(),
        pluginOptions: _options,
        modelRef: compatOaiModelRef(name: actionName, namespace: _options.name),
      );
    }
    if (actionType == 'bidi-model' && isRealtimeModelName(actionName)) {
      return defineCompatOpenAIRealtimeModel(
        name: toModelName(actionName, _options.name),
        client: _createClient(),
        pluginOptions: _options,
      );
    }
    return null;
  }

  @override
  Future<List<ActionMetadata<dynamic, dynamic, dynamic, dynamic>>>
  list() async {
    final listActions = _options.listActions;
    if (listActions == null || _options.apiKeyDisabled) {
      return const <ActionMetadata<dynamic, dynamic, dynamic, dynamic>>[];
    }
    if (_listActionsCache != null) {
      return _listActionsCache!;
    }
    final actions = await listActions(_createClient());
    _listActionsCache = actions;
    return actions;
  }
}

GenkitPlugin openAICompatible(PluginOptions options) {
  return OpenAICompatiblePlugin(options);
}
