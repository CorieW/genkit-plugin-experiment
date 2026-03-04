import 'dart:async';

import 'package:genkit/plugin.dart';

import 'client.dart';

typedef CompatInitializer =
    FutureOr<List<Action>> Function(CompatOpenAIClient client);
typedef CompatResolver =
    FutureOr<Action?> Function(
      CompatOpenAIClient client,
      String actionType,
      String actionName,
    );
typedef CompatListActions =
    FutureOr<List<ActionMetadata<dynamic, dynamic, dynamic, dynamic>>> Function(
      CompatOpenAIClient client,
    );

class PluginOptions {
  final String name;
  final Object? apiKey;
  final String? baseUrl;
  final Map<String, String>? headers;
  final Duration? timeout;
  final CompatInitializer? initializer;
  final CompatResolver? resolver;
  final CompatListActions? listActions;

  const PluginOptions({
    required this.name,
    this.apiKey,
    this.baseUrl,
    this.headers,
    this.timeout,
    this.initializer,
    this.resolver,
    this.listActions,
  });

  String? get apiKeyOrNull => apiKey is String ? apiKey as String : null;
  bool get apiKeyDisabled => apiKey == false;

  PluginOptions copyWith({
    String? name,
    Object? apiKey = _sentinel,
    String? baseUrl,
    Map<String, String>? headers,
    Duration? timeout,
    CompatInitializer? initializer,
    CompatResolver? resolver,
    CompatListActions? listActions,
  }) {
    return PluginOptions(
      name: name ?? this.name,
      apiKey: apiKey == _sentinel ? this.apiKey : apiKey,
      baseUrl: baseUrl ?? this.baseUrl,
      headers: headers ?? this.headers,
      timeout: timeout ?? this.timeout,
      initializer: initializer ?? this.initializer,
      resolver: resolver ?? this.resolver,
      listActions: listActions ?? this.listActions,
    );
  }
}

const Object _sentinel = Object();
