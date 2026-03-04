import 'package:genkit/genkit.dart';
import 'package:genkit_compat_oai/genkit_compat_oai.dart';
import 'package:test/test.dart';

void main() {
  group('toModelName', () {
    test('removes standard prefixes', () {
      expect(toModelName('/model/gpt-4'), 'gpt-4');
      expect(toModelName('/models/gpt-4'), 'gpt-4');
      expect(toModelName('/background-model/gpt-4'), 'gpt-4');
      expect(toModelName('/embedder/gpt-4'), 'gpt-4');
      expect(toModelName('/embedders/gpt-4'), 'gpt-4');
    });

    test('removes custom prefix', () {
      expect(toModelName('custom/gpt-4', 'custom'), 'gpt-4');
      expect(toModelName('/model/custom/gpt-4', 'custom'), 'gpt-4');
      expect(toModelName('/model/custom/gpt-4/v2', 'custom'), 'gpt-4/v2');
    });

    test('does not remove prefix when not provided', () {
      expect(toModelName('custom/gpt-4'), 'custom/gpt-4');
      expect(toModelName('/model/custom/gpt-4'), 'custom/gpt-4');
    });
  });

  group('maybeCreateRequestScopedOpenAIClient', () {
    test('returns default client when request has no apiKey', () {
      final defaultClient = CompatOpenAIClient(
        apiKey: 'default-key',
        baseUrl: 'https://example.com/v1',
      );
      final request = ModelRequest(messages: <Message>[]);
      final scoped = maybeCreateRequestScopedOpenAIClient(
        null,
        request,
        defaultClient,
      );
      expect(identical(scoped, defaultClient), isTrue);
    });

    test('creates a request-scoped client with request api key', () {
      final defaultClient = CompatOpenAIClient(
        apiKey: 'default-key',
        baseUrl: 'https://example.com/v1',
      );
      final request = ModelRequest(
        messages: <Message>[],
        config: <String, dynamic>{'apiKey': 'scoped-key'},
      );
      final scoped = maybeCreateRequestScopedOpenAIClient(
        null,
        request,
        defaultClient,
      );
      expect(identical(scoped, defaultClient), isFalse);
      expect(scoped.apiKey, 'scoped-key');
      expect(scoped.baseUrl, 'https://example.com/v1');
    });
  });
}
