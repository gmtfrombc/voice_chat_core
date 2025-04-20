/// A core package for voice chat functionality, integrating speech-to-text,
/// text-to-speech (FlutterTTS, ElevenLabs), and OpenAI communication.
library voice_chat_core;

// Export Services
export 'src/services/speech_service.dart';
export 'src/services/elevenlabs_service.dart';

// Export Models
export 'src/models/message.dart';

// Export Enums (if they are defined outside classes and need public access)
// Assuming SpeechServiceState and TTSProvider are defined in speech_service.dart
// and are needed externally, they are implicitly exported via speech_service.dart.
// If they were in separate files, you would export them like:
// export 'src/enums/speech_service_state.dart';

/// A Calculator.
class Calculator {
  /// Returns [value] plus 1.
  int addOne(int value) => value + 1;
}
