import 'dart:io';

import 'package:genkit/genkit.dart';
import 'package:genkit_compat_oai/genkit_compat_oai.dart';
import 'package:schemantic/schemantic.dart';

Flow<String, String, void, void> defineModelResolutionFlow(Genkit ai) {
  return ai.defineFlow(
    name: 'modelResolution',
    inputSchema: SchemanticType.string(defaultValue: 'gpt-4o-mini'),
    outputSchema: SchemanticType.string(),
    fn: (modelName, _) async {
      final action = await ai.registry.lookupAction(
        'model',
        'openai/$modelName',
      );
      if (action == null) {
        return 'Model not found: openai/$modelName';
      }

      return [
        'name: ${action.name}',
        'actionType: ${action.actionType}',
        'metadata: ${action.metadata}',
      ].join('\n');
    },
  );
}

Flow<String, String, void, void> defineActionListFlow(Genkit ai) {
  return ai.defineFlow(
    name: 'actionList',
    inputSchema: SchemanticType.string(defaultValue: 'model'),
    outputSchema: SchemanticType.string(),
    fn: (actionTypeFilter, _) async {
      final actionType = actionTypeFilter.trim();
      final actions = await ai.registry.listActions();
      final filtered =
          actions
              .where((a) => actionType.isEmpty || a.actionType == actionType)
              .map((a) => '${a.actionType}: ${a.name}')
              .toList()
            ..sort();
      return filtered.join('\n');
    },
  );
}

void main() {
  final ai = Genkit(
    plugins: [openAI(apiKey: Platform.environment['OPENAI_API_KEY'])],
  );

  defineModelResolutionFlow(ai);
  defineActionListFlow(ai);
}
