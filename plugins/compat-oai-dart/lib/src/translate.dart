import 'package:genkit/genkit.dart';
import 'package:genkit/plugin.dart';

import 'audio.dart';
import 'client.dart';
import 'options.dart';
import 'utils.dart';

typedef TranslationRequestBuilder =
    void Function(ModelRequest req, Map<String, dynamic> params);

final ModelInfo translationModelInfo = ModelInfo(
  supports: <String, dynamic>{
    'media': true,
    'output': <String>['text', 'json'],
    'multiturn': false,
    'systemRole': false,
    'tools': false,
  },
);

Map<String, dynamic> toTranslationRequest(
  String modelName,
  ModelRequest request, {
  TranslationRequestBuilder? requestBuilder,
}) {
  final params = toSttRequest(modelName, request);
  params.remove('stream');
  if (requestBuilder != null) {
    requestBuilder(request, params);
  }
  return params;
}

ModelResponse translationToGenerateResponse(dynamic result) {
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

Model defineCompatOpenAITranslationModel({
  required String name,
  required CompatOpenAIClient client,
  PluginOptions? pluginOptions,
  ModelRef<Map<String, dynamic>>? modelRef,
  ModelInfo? info,
  TranslationRequestBuilder? requestBuilder,
}) {
  final modelName = toModelName(name, pluginOptions?.name);
  final actionName =
      modelRef?.name ?? '${pluginOptions?.name ?? 'compat-oai'}/$modelName';

  return Model(
    name: actionName,
    metadata: Map<String, dynamic>.from(
      modelMetadata(
        actionName,
        modelInfo: info ?? translationModelInfo,
      ).metadata,
    ),
    fn: (request, _) async {
      if (request == null) {
        throw GenkitException(
          'Model request is required.',
          status: StatusCodes.INVALID_ARGUMENT,
        );
      }
      final params = toTranslationRequest(
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
      final result = await scoped.createTranslation(fields: params, file: file);
      return translationToGenerateResponse(result);
    },
  );
}

ModelRef<Map<String, dynamic>> compatOaiTranslationModelRef({
  required String name,
  String? namespace,
}) {
  final namespaced = namespace == null || name.startsWith('$namespace/')
      ? name
      : '$namespace/$name';
  return modelRef(namespaced);
}
