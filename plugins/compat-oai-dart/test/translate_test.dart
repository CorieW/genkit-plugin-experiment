import 'package:genkit/genkit.dart';
import 'package:genkit_compat_oai/genkit_compat_oai.dart';
import 'package:test/test.dart';

void main() {
  group('toTranslationRequest', () {
    test('builds translation request for base64 audio', () {
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
              TextPart(text: 'Translate this file'),
            ],
          ),
        ],
        output: OutputConfig(format: 'text'),
      );
      final actual = toTranslationRequest('whisper-1', request);
      expect(actual['model'], 'whisper-1');
      expect(actual['file'], isA<CompatUploadFile>());
      expect(actual['prompt'], 'Translate this file');
      expect(actual['response_format'], 'text');
    });
  });

  group('translationToGenerateResponse', () {
    test('maps string response', () {
      final result = translationToGenerateResponse('hello');
      expect(result.message?.text, 'hello');
      expect(result.finishReason, FinishReason.stop);
    });

    test('maps json response', () {
      final result = translationToGenerateResponse(<String, dynamic>{
        'text': 'hello',
      });
      expect(result.message?.text, 'hello');
      expect(result.finishReason, FinishReason.stop);
    });
  });
}
