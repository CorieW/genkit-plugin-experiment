import 'package:genkit/genkit.dart';
import 'package:genkit/plugin.dart';

import 'client.dart';
import 'options.dart';
import 'utils.dart';

Embedder defineCompatOpenAIEmbedder({
  required String name,
  required CompatOpenAIClient client,
  PluginOptions? pluginOptions,
  EmbedderRef<Map<String, dynamic>>? embedderRef,
}) {
  final modelName = toModelName(name, pluginOptions?.name);
  final actionName =
      embedderRef?.name ?? '${pluginOptions?.name ?? 'compat-oai'}/$modelName';

  return Embedder(
    name: actionName,
    metadata: Map<String, dynamic>.from(embedderMetadata(actionName).metadata),
    fn: (req, _) async {
      if (req == null) {
        throw GenkitException(
          'Embed request is required.',
          status: StatusCodes.INVALID_ARGUMENT,
        );
      }
      final scoped = maybeCreateRequestScopedOpenAIClient(
        pluginOptions,
        req,
        client,
      );
      final options = Map<String, dynamic>.from(req.options ?? const {});
      final encodingFormat = options.remove('encodingFormat');

      final response = await scoped.createEmbedding(<String, dynamic>{
        'model': modelName,
        'input': req.input
            .map(
              (d) =>
                  d.content.where((p) => p.isText).map((p) => p.text!).join(),
            )
            .toList(),
        if (encodingFormat != null) 'encoding_format': encodingFormat,
        ...options,
      });

      final data = response['data'];
      final embeddings = <Embedding>[];
      if (data is List) {
        for (final item in data.whereType<Map>()) {
          final map = Map<String, dynamic>.from(item);
          final embedding =
              (map['embedding'] as List?)
                  ?.map((e) => (e as num).toDouble())
                  .toList() ??
              const <double>[];
          embeddings.add(Embedding(embedding: embedding));
        }
      }
      return EmbedResponse(embeddings: embeddings);
    },
  );
}
