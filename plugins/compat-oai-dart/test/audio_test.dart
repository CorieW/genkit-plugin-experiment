import 'package:genkit/genkit.dart';
import 'package:genkit_compat_oai/genkit_compat_oai.dart';
import 'package:test/test.dart';

void main() {
  group('toTTSRequest', () {
    test('builds speech request from prompt text', () {
      final request = ModelRequest(
        messages: <Message>[
          Message(
            role: Role.user,
            content: <Part>[TextPart(text: 'Hello')],
          ),
        ],
      );
      final actual = toTTSRequest('gpt-4o-mini-tts', request);
      expect(actual['model'], 'gpt-4o-mini-tts');
      expect(actual['input'], 'Hello');
      expect(actual['voice'], 'alloy');
    });
  });

  group('toSttRequest', () {
    test('builds transcription request for base64 audio', () {
      final request = ModelRequest(
        messages: <Message>[
          Message(
            role: Role.user,
            content: <Part>[
              MediaPart(
                media: Media(
                  contentType: 'audio/wav',
                  url: 'data:audio/wav;base64,aGVsbG8=',
                ),
              ),
            ],
          ),
        ],
        output: OutputConfig(format: 'text'),
      );
      final actual = toSttRequest('whisper-1', request);
      expect(actual['model'], 'whisper-1');
      expect(actual['file'], isA<CompatUploadFile>());
      expect(actual['response_format'], 'text');
    });

    test('throws when output format is media', () {
      final request = ModelRequest(
        messages: <Message>[
          Message(
            role: Role.user,
            content: <Part>[
              MediaPart(
                media: Media(
                  contentType: 'audio/wav',
                  url: 'data:audio/wav;base64,aGVsbG8=',
                ),
              ),
            ],
          ),
        ],
        output: OutputConfig(format: 'media'),
      );
      expect(
        () => toSttRequest('whisper-1', request),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('transcriptionToGenerateResponse', () {
    test('maps string response', () {
      final result = transcriptionToGenerateResponse('hello');
      expect(result.message?.text, 'hello');
      expect(result.finishReason, FinishReason.stop);
    });

    test('maps json response', () {
      final result = transcriptionToGenerateResponse(<String, dynamic>{
        'text': 'hello',
      });
      expect(result.message?.text, 'hello');
      expect(result.finishReason, FinishReason.stop);
    });
  });
}
