import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' as http_parser;
import 'package:meta/meta.dart';

class CompatUploadFile {
  final String filename;
  final String contentType;
  final Uint8List bytes;

  const CompatUploadFile({
    required this.filename,
    required this.contentType,
    required this.bytes,
  });
}

class OpenAIHttpException implements Exception {
  final String method;
  final Uri uri;
  final int? statusCode;
  final Object? body;
  final String message;

  OpenAIHttpException({
    required this.method,
    required this.uri,
    required this.message,
    this.statusCode,
    this.body,
  });

  @override
  String toString() {
    return 'OpenAIHttpException(method: $method, uri: $uri, statusCode: $statusCode, message: $message, body: $body)';
  }
}

class CompatBinaryResponse {
  final Uint8List bytes;
  final String? contentType;

  const CompatBinaryResponse({required this.bytes, this.contentType});
}

class CompatOpenAIClient {
  final String apiKey;
  final String baseUrl;
  final Map<String, String> headers;
  final Duration? timeout;
  final http.Client _httpClient;

  CompatOpenAIClient({
    required this.apiKey,
    required this.baseUrl,
    this.headers = const {},
    this.timeout,
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client();

  CompatOpenAIClient copyWith({
    String? apiKey,
    String? baseUrl,
    Map<String, String>? headers,
    Duration? timeout,
    http.Client? httpClient,
  }) {
    return CompatOpenAIClient(
      apiKey: apiKey ?? this.apiKey,
      baseUrl: baseUrl ?? this.baseUrl,
      headers: headers ?? this.headers,
      timeout: timeout ?? this.timeout,
      httpClient: httpClient ?? _httpClient,
    );
  }

  @visibleForTesting
  Uri buildUri(String path) {
    final trimmedBase = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$trimmedBase$normalizedPath');
  }

  Map<String, String> _requestHeaders({
    bool json = true,
    String? accept,
    Map<String, String>? extra,
  }) {
    return <String, String>{
      if (apiKey.isNotEmpty) 'authorization': 'Bearer $apiKey',
      if (json) 'content-type': 'application/json',
      if (accept != null) 'accept': accept,
      ...headers,
      ...?extra,
    };
  }

  Future<http.Response> _send(http.BaseRequest request) async {
    try {
      final streamed = timeout == null
          ? await _httpClient.send(request)
          : await _httpClient.send(request).timeout(timeout!);
      final response = await http.Response.fromStream(streamed);
      if (response.statusCode ~/ 100 != 2) {
        throw OpenAIHttpException(
          method: request.method,
          uri: request.url,
          statusCode: response.statusCode,
          body: response.body,
          message: 'Unsuccessful response',
        );
      }
      return response;
    } on OpenAIHttpException {
      rethrow;
    } catch (e) {
      throw OpenAIHttpException(
        method: request.method,
        uri: request.url,
        message: 'Response error',
        body: e,
      );
    }
  }

  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body, {
    Map<String, String>? extraHeaders,
  }) async {
    final uri = buildUri(path);
    final request = http.Request('POST', uri)
      ..headers.addAll(_requestHeaders(extra: extraHeaders))
      ..body = jsonEncode(body);
    final response = await _send(request);
    return _decodeJsonResponse(response);
  }

  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, String>? queryParameters,
    Map<String, String>? extraHeaders,
  }) async {
    var uri = buildUri(path);
    if (queryParameters != null && queryParameters.isNotEmpty) {
      uri = uri.replace(
        queryParameters: <String, String>{
          ...uri.queryParameters,
          ...queryParameters,
        },
      );
    }
    final request = http.Request('GET', uri)
      ..headers.addAll(
        _requestHeaders(
          json: false,
          accept: 'application/json',
          extra: extraHeaders,
        ),
      );
    final response = await _send(request);
    return _decodeJsonResponse(response);
  }

  Future<CompatBinaryResponse> getBinary(
    String path, {
    Map<String, String>? queryParameters,
    Map<String, String>? extraHeaders,
  }) async {
    var uri = buildUri(path);
    if (queryParameters != null && queryParameters.isNotEmpty) {
      uri = uri.replace(
        queryParameters: <String, String>{
          ...uri.queryParameters,
          ...queryParameters,
        },
      );
    }
    final request = http.Request('GET', uri)
      ..headers.addAll(
        _requestHeaders(json: false, accept: '*/*', extra: extraHeaders),
      );
    final response = await _send(request);
    return CompatBinaryResponse(
      bytes: response.bodyBytes,
      contentType: response.headers['content-type'],
    );
  }

  Future<List<Map<String, dynamic>>> listModels() async {
    final uri = buildUri('/models');
    final request = http.Request(
      'GET',
      uri,
    )..headers.addAll(_requestHeaders(json: false, accept: 'application/json'));
    final response = await _send(request);
    final decoded = _decodeJsonResponse(response);
    final data = decoded['data'];
    if (data is! List) return const [];
    return data
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  Future<Map<String, dynamic>> createChatCompletion(
    Map<String, dynamic> request,
  ) {
    return postJson('/chat/completions', request);
  }

  Uri buildRealtimeUri({required String model}) {
    final base = Uri.parse(baseUrl);
    var path = base.path;
    if (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    if (path.isEmpty) {
      path = '/v1';
    }

    final realtimePath = '$path/realtime';
    return base.replace(
      scheme: base.scheme == 'https'
          ? 'wss'
          : (base.scheme == 'http' ? 'ws' : base.scheme),
      path: realtimePath,
      queryParameters: <String, String>{'model': model},
    );
  }

  Future<WebSocket> connectRealtime({required String model}) async {
    final uri = buildRealtimeUri(model: model);
    final authHeaders = _requestHeaders(json: false);
    final wsHeaders = <String, dynamic>{
      ...authHeaders,
      if (!authHeaders.containsKey('OpenAI-Beta'))
        if (!authHeaders.containsKey('openai-beta'))
          'OpenAI-Beta': 'realtime=v1',
    };

    try {
      final socket = timeout == null
          ? await WebSocket.connect(uri.toString(), headers: wsHeaders)
          : await WebSocket.connect(
              uri.toString(),
              headers: wsHeaders,
            ).timeout(timeout!);
      return socket;
    } catch (e) {
      throw OpenAIHttpException(
        method: 'GET',
        uri: uri,
        message: 'Realtime connection error',
        body: e.toString(),
      );
    }
  }

  Stream<Map<String, dynamic>> createChatCompletionStream(
    Map<String, dynamic> request,
  ) async* {
    final uri = buildUri('/chat/completions');
    final req = http.Request('POST', uri)
      ..headers.addAll(_requestHeaders(accept: 'text/event-stream'))
      ..body = jsonEncode(request);

    late http.StreamedResponse streamed;
    try {
      streamed = timeout == null
          ? await _httpClient.send(req)
          : await _httpClient.send(req).timeout(timeout!);
    } catch (e) {
      throw OpenAIHttpException(
        method: 'POST',
        uri: uri,
        message: 'Response error',
        body: e,
      );
    }
    if (streamed.statusCode ~/ 100 != 2) {
      final body = await streamed.stream.bytesToString();
      throw OpenAIHttpException(
        method: 'POST',
        uri: uri,
        statusCode: streamed.statusCode,
        body: body,
        message: 'Unsuccessful response',
      );
    }

    final textStream = streamed.stream.transform(utf8.decoder);
    final buffer = StringBuffer();

    await for (final chunk in textStream) {
      buffer.write(chunk);
      final buffered = buffer.toString();
      final events = buffered.split('\n\n');
      if (events.length == 1) {
        continue;
      }

      buffer
        ..clear()
        ..write(events.removeLast());

      for (final event in events) {
        for (final line in event.split('\n')) {
          final trimmed = line.trim();
          if (!trimmed.startsWith('data:')) continue;
          final payload = trimmed.substring(5).trim();
          if (payload.isEmpty || payload == '[DONE]') {
            continue;
          }
          final decoded = jsonDecode(payload);
          if (decoded is Map<String, dynamic>) {
            yield decoded;
          } else if (decoded is Map) {
            yield Map<String, dynamic>.from(decoded);
          }
        }
      }
    }
  }

  Future<Map<String, dynamic>> createEmbedding(Map<String, dynamic> request) {
    return postJson('/embeddings', request);
  }

  Future<Map<String, dynamic>> createImage(Map<String, dynamic> request) {
    return postJson('/images/generations', request);
  }

  Future<Map<String, dynamic>> createVideo(Map<String, dynamic> request) {
    return postJson('/videos', request);
  }

  Future<Map<String, dynamic>> retrieveVideo(String id) {
    return getJson('/videos/$id');
  }

  Future<CompatBinaryResponse> retrieveVideoContent(
    String id, {
    String? variant,
  }) {
    return getBinary(
      '/videos/$id/content',
      queryParameters: variant == null || variant.trim().isEmpty
          ? null
          : <String, String>{'variant': variant.trim()},
    );
  }

  Future<Uint8List> createSpeech(Map<String, dynamic> request) async {
    final uri = buildUri('/audio/speech');
    final req = http.Request('POST', uri)
      ..headers.addAll(_requestHeaders(accept: '*/*'))
      ..body = jsonEncode(request);
    final response = await _send(req);
    return response.bodyBytes;
  }

  Future<dynamic> createTranscription({
    required Map<String, dynamic> fields,
    required CompatUploadFile file,
  }) {
    return _postMultipart('/audio/transcriptions', fields: fields, file: file);
  }

  Future<dynamic> createTranslation({
    required Map<String, dynamic> fields,
    required CompatUploadFile file,
  }) {
    return _postMultipart('/audio/translations', fields: fields, file: file);
  }

  Future<dynamic> _postMultipart(
    String path, {
    required Map<String, dynamic> fields,
    required CompatUploadFile file,
  }) async {
    final uri = buildUri(path);
    final request = http.MultipartRequest('POST', uri);
    request.headers.addAll(_requestHeaders(json: false, accept: '*/*'));

    fields.forEach((key, value) {
      if (value == null) return;
      request.fields[key] = value.toString();
    });

    request.files.add(
      http.MultipartFile.fromBytes(
        'file',
        file.bytes,
        filename: file.filename,
        contentType: http_parser.MediaType.parse(file.contentType),
      ),
    );

    late http.StreamedResponse streamed;
    try {
      streamed = timeout == null
          ? await _httpClient.send(request)
          : await _httpClient.send(request).timeout(timeout!);
    } catch (e) {
      throw OpenAIHttpException(
        method: 'POST',
        uri: uri,
        message: 'Response error',
        body: e,
      );
    }
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode ~/ 100 != 2) {
      throw OpenAIHttpException(
        method: 'POST',
        uri: uri,
        statusCode: response.statusCode,
        message: 'Unsuccessful response',
        body: response.body,
      );
    }

    final contentType = response.headers['content-type'] ?? '';
    if (contentType.contains('application/json')) {
      return _decodeJsonResponse(response);
    }
    return response.body;
  }

  Map<String, dynamic> _decodeJsonResponse(http.Response response) {
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
    throw OpenAIHttpException(
      method: 'POST',
      uri: response.request?.url ?? Uri(),
      message: 'Expected JSON object response',
      body: decoded,
    );
  }
}
