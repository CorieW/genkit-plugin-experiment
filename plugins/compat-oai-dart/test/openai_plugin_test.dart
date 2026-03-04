import 'dart:convert';
import 'dart:io';

import 'package:genkit/genkit.dart';
import 'package:genkit_compat_oai/genkit_compat_oai.dart';
import 'package:test/test.dart';

void main() {
  group('openAIPlugin dynamic model registration', () {
    test(
      'initializes actions from /models without baked-in model IDs',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() async {
          await server.close(force: true);
        });

        server.listen((request) async {
          if (request.method == 'GET' && request.uri.path.endsWith('/models')) {
            request.response.statusCode = HttpStatus.ok;
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              jsonEncode(<String, dynamic>{
                'data': <Map<String, dynamic>>[
                  <String, dynamic>{'id': 'gpt-4o-mini'},
                  <String, dynamic>{'id': 'text-embedding-3-small'},
                ],
              }),
            );
            await request.response.close();
            return;
          }

          request.response.statusCode = HttpStatus.notFound;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode(<String, dynamic>{'error': 'nope'}),
          );
          await request.response.close();
        });

        final plugin = openAIPlugin(
          apiKey: 'test-key',
          baseUrl: 'http://127.0.0.1:${server.port}/v1',
        );
        final actions = await plugin.init();
        final actionNames = actions.map((action) => action.name).toSet();

        expect(actionNames, contains('openai/gpt-4o-mini'));
        expect(actionNames, contains('openai/text-embedding-3-small'));
        expect(actionNames, isNot(contains('openai/gpt-4.5')));
      },
    );
  });

  group('openAIPlugin reference normalization', () {
    test('normalizes already-namespaced model and embedder names', () {
      final plugin = openAIPlugin(apiKey: 'test-key');

      final modelAction = plugin.resolve('model', '/model/openai/gpt-4o-mini');
      expect(modelAction, isA<Model>());
      expect((modelAction! as Model).name, 'openai/gpt-4o-mini');

      final embedderAction = plugin.resolve(
        'embedder',
        '/embedder/openai/text-embedding-3-small',
      );
      expect(embedderAction, isA<Embedder>());
      expect(
        (embedderAction! as Embedder).name,
        'openai/text-embedding-3-small',
      );
    });
  });

  group('openAIPlugin image model routing', () {
    test('routes chatgpt-image-latest to /images/generations', () async {
      final seenPaths = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        seenPaths.add(request.uri.path);
        final body = await utf8.decoder.bind(request).join();

        if (request.uri.path.endsWith('/images/generations')) {
          final decoded = jsonDecode(body) as Map<String, dynamic>;
          expect(decoded['model'], 'chatgpt-image-latest');
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode(<String, dynamic>{
              'data': <Map<String, dynamic>>[
                <String, dynamic>{'b64_json': 'aGVsbG8='},
              ],
            }),
          );
          await request.response.close();
          return;
        }

        request.response.statusCode = HttpStatus.internalServerError;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(<String, dynamic>{
            'error': <String, dynamic>{'message': 'unexpected route'},
          }),
        );
        await request.response.close();
      });

      final plugin = openAIPlugin(
        apiKey: 'test-key',
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
      );

      final action = plugin.resolve('model', 'chatgpt-image-latest');
      expect(action, isNotNull);

      final response = await (action! as Model)(
        ModelRequest(
          messages: <Message>[
            Message(
              role: Role.user,
              content: <Part>[TextPart(text: 'Draw a cat')],
            ),
          ],
        ),
      );

      expect(
        response.message?.content.any((part) => part.media != null),
        isTrue,
      );
      expect(seenPaths, contains('/v1/images/generations'));
      expect(seenPaths, isNot(contains('/v1/chat/completions')));
    });

    test('lists chatgpt-image-latest with image model metadata', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        if (request.method == 'GET' && request.uri.path.endsWith('/models')) {
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode(<String, dynamic>{
              'data': <Map<String, dynamic>>[
                <String, dynamic>{'id': 'chatgpt-image-latest'},
                <String, dynamic>{'id': 'gpt-4o-mini'},
              ],
            }),
          );
          await request.response.close();
          return;
        }

        request.response.statusCode = HttpStatus.notFound;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(<String, dynamic>{'error': 'nope'}));
        await request.response.close();
      });

      final plugin = openAIPlugin(
        apiKey: 'test-key',
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
      );
      final actions = await plugin.list();
      final imageAction = actions.firstWhere(
        (action) => action.name == 'openai/chatgpt-image-latest',
      );

      final metadata = imageAction.metadata['model'] as Map<String, dynamic>;
      final supports = metadata['supports'] as Map<String, dynamic>;
      expect(supports['output'], contains('media'));
      expect(supports['tools'], isFalse);
    });
  });

  group('openAIPlugin video model routing', () {
    test('routes sora-2-pro to /videos and returns media output', () async {
      final seenPaths = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        seenPaths.add(request.uri.path);

        if (request.method == 'POST' && request.uri.path.endsWith('/videos')) {
          final body = await utf8.decoder.bind(request).join();
          final decoded = jsonDecode(body) as Map<String, dynamic>;
          expect(decoded['model'], 'sora-2-pro');
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode(<String, dynamic>{
              'id': 'vid_123',
              'status': 'completed',
            }),
          );
          await request.response.close();
          return;
        }

        if (request.method == 'GET' &&
            request.uri.path.endsWith('/videos/vid_123/content')) {
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType('video', 'mp4');
          request.response.add(<int>[0, 1, 2, 3]);
          await request.response.close();
          return;
        }

        request.response.statusCode = HttpStatus.internalServerError;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(<String, dynamic>{
            'error': <String, dynamic>{'message': 'unexpected route'},
          }),
        );
        await request.response.close();
      });

      final plugin = openAIPlugin(
        apiKey: 'test-key',
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
      );

      final action = plugin.resolve('model', 'sora-2-pro');
      expect(action, isNotNull);

      final response = await (action! as Model)(
        ModelRequest(
          messages: <Message>[
            Message(
              role: Role.user,
              content: <Part>[TextPart(text: 'A cinematic ocean scene')],
            ),
          ],
        ),
      );

      final mediaParts =
          response.message?.content.where((part) => part.media != null) ??
          const <Part>[];
      expect(mediaParts, isNotEmpty);
      expect(
        mediaParts.first.media?.url,
        startsWith('data:video/mp4;base64,AAECAw=='),
      );
      expect(seenPaths, contains('/v1/videos'));
      expect(seenPaths, contains('/v1/videos/vid_123/content'));
      expect(seenPaths, isNot(contains('/v1/chat/completions')));
    });

    test('lists sora-2-pro with video model metadata', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        if (request.method == 'GET' && request.uri.path.endsWith('/models')) {
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode(<String, dynamic>{
              'data': <Map<String, dynamic>>[
                <String, dynamic>{'id': 'sora-2-pro'},
                <String, dynamic>{'id': 'gpt-4o-mini'},
              ],
            }),
          );
          await request.response.close();
          return;
        }

        request.response.statusCode = HttpStatus.notFound;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(<String, dynamic>{'error': 'nope'}));
        await request.response.close();
      });

      final plugin = openAIPlugin(
        apiKey: 'test-key',
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
      );
      final actions = await plugin.list();
      final videoAction = actions.firstWhere(
        (action) => action.name == 'openai/sora-2-pro',
      );

      final metadata = videoAction.metadata['model'] as Map<String, dynamic>;
      final supports = metadata['supports'] as Map<String, dynamic>;
      expect(supports['output'], contains('media'));
      expect(supports['tools'], isFalse);
    });
  });
}
