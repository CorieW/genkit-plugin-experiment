import 'dart:async';
import 'dart:convert';

import 'package:genkit/genkit.dart';
import 'package:genkit/plugin.dart';

import 'client.dart';
import 'options.dart';
import 'utils.dart';

typedef VideoRequestBuilder =
    void Function(ModelRequest req, Map<String, dynamic> params);

final ModelInfo videoGenerationModelInfo = ModelInfo(
  supports: <String, dynamic>{
    'media': false,
    'output': <String>['media'],
    'multiturn': false,
    'systemRole': false,
    'tools': false,
  },
);

Map<String, dynamic> toVideoGenerateParams(
  String modelName,
  ModelRequest request, {
  VideoRequestBuilder? requestBuilder,
}) {
  final config = Map<String, dynamic>.from(request.config ?? const {});
  final modelVersion = config.remove('version');
  config.remove('temperature');
  config.remove('maxOutputTokens');
  config.remove('stopSequences');
  config.remove('topK');
  config.remove('topP');
  config.remove('pollIntervalMs');
  config.remove('pollTimeoutMs');
  config.remove('variant');
  config.remove('apiKey');

  final options = <String, dynamic>{
    'model': modelVersion ?? modelName,
    'prompt': request.messages.first.text,
  };

  if (requestBuilder != null) {
    requestBuilder(request, options);
  } else {
    options.addAll(config);
  }

  options.removeWhere((_, value) => value == null);
  return options;
}

bool _isVideoJobCompleted(Map<String, dynamic> job) {
  final status = (job['status'] as String?)?.toLowerCase();
  return status == 'completed';
}

bool _isVideoJobFailed(Map<String, dynamic> job) {
  final status = (job['status'] as String?)?.toLowerCase();
  return status == 'failed' || status == 'cancelled';
}

String? _videoJobErrorMessage(Map<String, dynamic> job) {
  final error = job['error'];
  if (error is Map) {
    final message = error['message'];
    if (message is String && message.isNotEmpty) {
      return message;
    }
  }
  return null;
}

Duration _durationFromConfig(
  Map<String, dynamic>? config,
  String key,
  Duration fallback,
) {
  final value = config?[key];
  if (value is num && value > 0) {
    return Duration(milliseconds: value.toInt());
  }
  return fallback;
}

Future<Map<String, dynamic>> _pollVideoJob(
  CompatOpenAIClient client,
  Map<String, dynamic> initialJob, {
  required Duration pollInterval,
  required Duration pollTimeout,
}) async {
  var job = initialJob;
  final id = job['id'] as String?;
  if (id == null || id.isEmpty) {
    throw GenkitException(
      'Video generation response did not include an id.',
      status: StatusCodes.INTERNAL,
      details: initialJob.toString(),
    );
  }

  final deadline = DateTime.now().add(pollTimeout);
  while (true) {
    if (_isVideoJobCompleted(job) || _isVideoJobFailed(job)) {
      return job;
    }
    if (DateTime.now().isAfter(deadline)) {
      throw GenkitException(
        'Timed out waiting for video generation for "$id".',
        status: StatusCodes.UNAVAILABLE,
        details: 'Last status: ${job['status']}',
      );
    }
    await Future<void>.delayed(pollInterval);
    job = await client.retrieveVideo(id);
  }
}

ModelResponse videoToGenerateResponse({
  required Map<String, dynamic> videoJob,
  required CompatBinaryResponse content,
}) {
  final normalizedContentType = (content.contentType ?? 'video/mp4')
      .split(';')
      .first
      .trim();
  final media = Media(
    contentType: normalizedContentType.isEmpty
        ? 'video/mp4'
        : normalizedContentType,
    url:
        'data:${normalizedContentType.isEmpty ? 'video/mp4' : normalizedContentType};base64,${base64Encode(content.bytes)}',
  );
  return ModelResponse(
    finishReason: FinishReason.stop,
    message: Message(
      role: Role.model,
      content: <Part>[MediaPart(media: media)],
    ),
    raw: <String, dynamic>{'video': videoJob},
  );
}

Model defineCompatOpenAIVideoModel({
  required String name,
  required CompatOpenAIClient client,
  PluginOptions? pluginOptions,
  ModelRef<Map<String, dynamic>>? modelRef,
  ModelInfo? info,
  VideoRequestBuilder? requestBuilder,
}) {
  final modelName = toModelName(name, pluginOptions?.name);
  final actionName =
      modelRef?.name ?? '${pluginOptions?.name ?? 'compat-oai'}/$modelName';

  return Model(
    name: actionName,
    metadata: Map<String, dynamic>.from(
      modelMetadata(
        actionName,
        modelInfo: info ?? videoGenerationModelInfo,
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
      final params = toVideoGenerateParams(
        modelName,
        request,
        requestBuilder: requestBuilder,
      );
      final videoJob = await scoped.createVideo(params);
      final pollInterval = _durationFromConfig(
        request.config,
        'pollIntervalMs',
        const Duration(seconds: 2),
      );
      final pollTimeout = _durationFromConfig(
        request.config,
        'pollTimeoutMs',
        const Duration(minutes: 5),
      );
      final completedVideoJob = await _pollVideoJob(
        scoped,
        videoJob,
        pollInterval: pollInterval,
        pollTimeout: pollTimeout,
      );
      if (_isVideoJobFailed(completedVideoJob)) {
        throw GenkitException(
          'Video generation failed for "$modelName".',
          status: StatusCodes.UNAVAILABLE,
          details:
              _videoJobErrorMessage(completedVideoJob) ??
              completedVideoJob.toString(),
        );
      }
      final id = completedVideoJob['id'] as String?;
      if (id == null || id.isEmpty) {
        throw GenkitException(
          'Video generation completed but the response did not include an id.',
          status: StatusCodes.INTERNAL,
          details: completedVideoJob.toString(),
        );
      }
      final variant = request.config?['variant'] as String?;
      final content = await scoped.retrieveVideoContent(id, variant: variant);
      return videoToGenerateResponse(
        videoJob: completedVideoJob,
        content: content,
      );
    },
  );
}

ModelRef<Map<String, dynamic>> compatOaiVideoModelRef({
  required String name,
  String? namespace,
}) {
  final namespaced = namespace == null || name.startsWith('$namespace/')
      ? name
      : '$namespace/$name';
  return modelRef(namespaced);
}
