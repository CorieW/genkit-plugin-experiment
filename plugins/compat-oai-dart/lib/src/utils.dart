import 'package:genkit/genkit.dart';

import 'client.dart';
import 'options.dart';

CompatOpenAIClient maybeCreateRequestScopedOpenAIClient(
  PluginOptions? pluginOptions,
  Object? request,
  CompatOpenAIClient defaultClient,
) {
  String? requestApiKey;
  if (request is ModelRequest) {
    requestApiKey = request.config?['apiKey'] as String?;
  } else if (request is EmbedRequest) {
    requestApiKey = request.options?['apiKey'] as String?;
  }
  if (requestApiKey == null || requestApiKey.isEmpty) {
    return defaultClient;
  }

  final scopedOptions = pluginOptions;
  return CompatOpenAIClient(
    apiKey: requestApiKey,
    baseUrl: scopedOptions?.baseUrl ?? defaultClient.baseUrl,
    headers: scopedOptions?.headers ?? defaultClient.headers,
    timeout: scopedOptions?.timeout ?? defaultClient.timeout,
  );
}

String toModelName(String name, [String? prefix]) {
  final refPrefixes = RegExp(
    r'^/(background-model|model|models|embedder|embedders)/',
  );
  final maybePluginRef = name.replaceFirst(refPrefixes, '');
  if (prefix != null && prefix.isNotEmpty) {
    final pluginPrefix = RegExp('^${RegExp.escape(prefix)}/');
    return maybePluginRef.replaceFirst(pluginPrefix, '');
  }
  return maybePluginRef;
}
