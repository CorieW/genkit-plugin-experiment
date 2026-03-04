import 'package:genkit/genkit.dart';
import 'package:genkit/plugin.dart';

import 'client.dart';
import 'options.dart';
import 'utils.dart';

typedef ImageRequestBuilder =
    void Function(ModelRequest req, Map<String, dynamic> params);

final ModelInfo imageGenerationModelInfo = ModelInfo(
  supports: <String, dynamic>{
    'media': false,
    'output': <String>['media'],
    'multiturn': false,
    'systemRole': false,
    'tools': false,
  },
);

Map<String, dynamic> toImageGenerateParams(
  String modelName,
  ModelRequest request, {
  ImageRequestBuilder? requestBuilder,
}) {
  final config = Map<String, dynamic>.from(request.config ?? const {});
  final modelVersion = config.remove('version');
  config.remove('temperature');
  config.remove('maxOutputTokens');
  config.remove('stopSequences');
  config.remove('topK');
  config.remove('topP');

  final options = <String, dynamic>{
    'model': modelVersion ?? modelName,
    'prompt': request.messages.first.text,
    'response_format': config['response_format'] ?? 'b64_json',
  };

  if (requestBuilder != null) {
    requestBuilder(request, options);
  } else {
    options.addAll(config);
  }

  options.removeWhere((_, value) => value == null);
  return options;
}

ModelResponse imageToGenerateResponse(Map<String, dynamic> result) {
  final images = result['data'];
  if (images is! List || images.isEmpty) {
    return ModelResponse(finishReason: FinishReason.stop);
  }

  final content = <Part>[];
  for (final item in images.whereType<Map>()) {
    final map = Map<String, dynamic>.from(item);
    final b64 = map['b64_json'] as String?;
    final url =
        map['url'] as String? ??
        (b64 == null ? '' : 'data:image/png;base64,$b64');
    if (url.isEmpty) continue;
    content.add(
      MediaPart(
        media: Media(contentType: 'image/png', url: url),
      ),
    );
  }

  return ModelResponse(
    finishReason: FinishReason.stop,
    message: Message(role: Role.model, content: content),
    raw: result,
  );
}

Model defineCompatOpenAIImageModel({
  required String name,
  required CompatOpenAIClient client,
  PluginOptions? pluginOptions,
  ModelRef<Map<String, dynamic>>? modelRef,
  ModelInfo? info,
  ImageRequestBuilder? requestBuilder,
}) {
  final modelName = toModelName(name, pluginOptions?.name);
  final actionName =
      modelRef?.name ?? '${pluginOptions?.name ?? 'compat-oai'}/$modelName';

  return Model(
    name: actionName,
    metadata: Map<String, dynamic>.from(
      modelMetadata(
        actionName,
        modelInfo: info ?? imageGenerationModelInfo,
      ).metadata,
    ),
    fn: (request, _) async {
      if (request == null) {
        throw GenkitException(
          'Model request is required.',
          status: StatusCodes.INVALID_ARGUMENT,
        );
      }
      final scoped = maybeCreateRequestScopedOpenAIClient(
        pluginOptions,
        request,
        client,
      );
      final result = await scoped.createImage(
        toImageGenerateParams(
          modelName,
          request,
          requestBuilder: requestBuilder,
        ),
      );
      return imageToGenerateResponse(result);
    },
  );
}

ModelRef<Map<String, dynamic>> compatOaiImageModelRef({
  required String name,
  String? namespace,
}) {
  final namespaced = namespace == null || name.startsWith('$namespace/')
      ? name
      : '$namespace/$name';
  return modelRef(namespaced);
}
