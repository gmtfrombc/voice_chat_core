import 'dart:async';
// import 'dart:convert'; // Removed unused
import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:flutter_tts/flutter_tts.dart';
// import 'package:http/http.dart' as http; // Removed unused import
// import 'dart:io'; // Removed unused
import '../models/message.dart'; // Correct path within the package
import 'elevenlabs_service.dart'; // Correct path within the package
// ignore: unused_import - Linter incorrectly flags this, but AudioSession type IS used in constructor.
import 'package:audio_session/audio_session.dart';
import 'package:dart_openai/dart_openai.dart'; // Import dart_openai
import 'package:just_audio/just_audio.dart';

enum SpeechServiceState { idle, listening, speaking, processing }

enum TTSProvider { flutterTTS, elevenLabs }

/// Service to handle voice-based communication with OpenAI
class SpeechService {
  // Configuration - to be injected later
  late final String _openAiApiKey;

  // Speech recognition
  final SpeechToText _speechToText = SpeechToText();

  // Text-to-speech
  final FlutterTts _flutterTts = FlutterTts();

  // ElevenLabs service for natural voice
  late final ElevenLabsService _elevenLabsService; // Will be initialized later

  // Audio Session instance (injected)
  late final AudioSession _audioSession; // Instance is used in methods below

  // TTS provider selection
  TTSProvider _ttsProvider = TTSProvider.elevenLabs;

  // State management
  bool _isListening = false;
  SpeechServiceState _currentState = SpeechServiceState.idle;

  // Conversation history
  final List<Message> _messages = [];

  // Controllers for events
  final _speechController = StreamController<String>.broadcast();
  final _stateController = StreamController<SpeechServiceState>.broadcast();
  final _messagesController = StreamController<Message>.broadcast();

  // Streams for UI components to listen to
  Stream<String> get onSpeechResult => _speechController.stream;
  Stream<SpeechServiceState> get onStateChanged => _stateController.stream;
  Stream<Message> get onMessageReceived => _messagesController.stream;

  // Conversation history
  List<Message> get messages => List.unmodifiable(_messages);

  // Internal variable to hold the system prompt
  String _systemPrompt = 'You are a helpful AI assistant.'; // Default prompt

  // Internal flag for triage completion
  bool _isTriageComplete = false;

  // Flag to determine output modality (true=Voice, false=Text, null=Undecided)
  bool? _useVoiceOutput;

  // Get current TTS provider
  TTSProvider get ttsProvider => _ttsProvider;

  // Set TTS provider
  set ttsProvider(TTSProvider provider) {
    _ttsProvider = provider;
  }

  // Constructor requires configuration and AudioSession
  SpeechService({
    required String openAiApiKey,
    // openAiChatUrl parameter removed as it wasn't used
    required ElevenLabsService elevenLabsService,
    required AudioSession audioSession,
  }) {
    _openAiApiKey = openAiApiKey;
    _elevenLabsService = elevenLabsService;
    _audioSession = audioSession;
    // Initialize OpenAI API Key here
    OpenAI.apiKey = _openAiApiKey;
    // Consider adding organization ID if needed: OpenAI.organization = "ORG_ID";
  }

  // Initialize speech services
  Future<void> initialize() async {
    // Initialize speech recognition with error and status handlers
    bool available = await _speechToText.initialize(
      onError: (errorNotification) async {
        // onError is correct here
        debugPrint(
            'Speech recognition init/global error: ${errorNotification.errorMsg}');
        if (_isListening) {
          _isListening = false;
          try {
            await _audioSession.setActive(false);
            debugPrint(
                "Audio session deactivated due to STT init/global error.");
          } catch (e) {
            debugPrint("Error deactivating audio session in STT onError: $e");
          }
          _updateState(SpeechServiceState.idle);
        }
      },
      onStatus: (status) async {
        // onStatus is correct here
        debugPrint('Speech recognition global status: $status');
        // Handle global status changes, e.g., permissions, availability
        if (status == 'notListening' && _isListening) {
          // This might indicate an unexpected stop or permission issue
          _isListening = false;
          try {
            await _audioSession.setActive(false);
            debugPrint(
                "Audio session deactivated due to global 'notListening' status while _isListening was true.");
          } catch (e) {
            debugPrint(
                "Error deactivating audio session in global onStatus: $e");
          }
          _updateState(SpeechServiceState.idle);
        } else if (status == 'done' && _isListening) {
          // If listener completes naturally and reports 'done' globally
          _isListening = false;
          // Should have already been handled by onResult's final result,
          // but good to catch here too. Ensure state is updated appropriately.
          if (_currentState != SpeechServiceState.processing) {
            _updateState(
                SpeechServiceState.idle); // Go idle if not already processing
          }
        }
      },
    );

    await _flutterTts.setLanguage("en-US");
    await _flutterTts.setPitch(1.0);
    await _flutterTts.setSpeechRate(0.5);

    debugPrint(
        'Speech service initialized. Speech recognition available: $available');
    debugPrint(
        'Using TTS provider: ${_ttsProvider == TTSProvider.elevenLabs ? "ElevenLabs" : "Flutter TTS"}');
    if (!available) {
      debugPrint('Speech recognition not available');
    }
  }

  Future<void> initiateVoiceFlow() async {
    _useVoiceOutput ??= true;
    await _speak("Hi there, what can I help you with today?");
  }

  Future<void> _speak(String text) async {
    if (text.isEmpty) {
      _updateState(SpeechServiceState.idle);
      return;
    }
    final textToSpeak = text.replaceAll("[TRIAGE_COMPLETE]", "").trim();
    if (textToSpeak.isEmpty) {
      debugPrint(
          'Text became empty after removing TRIAGE_COMPLETE token. Skipping speech.');
      _updateState(SpeechServiceState.idle);
      return;
    }

    _updateState(SpeechServiceState.speaking);

    StreamSubscription<PlayerState>? playerStateSubscription;
    Future<void> cancelPlaybackListeners() async {
      await playerStateSubscription?.cancel();
      playerStateSubscription = null;
    }

    try {
      if (!await _audioSession.setActive(true)) {/* Okay if already active */}
      debugPrint("Audio session activated/verified active for TTS playback.");

      if (_ttsProvider == TTSProvider.elevenLabs) {
        playerStateSubscription =
            _elevenLabsService.playerProcessingStateStream.listen(
          (state) async {
            if (state.processingState == ProcessingState.completed) {
              await cancelPlaybackListeners();
              debugPrint("TTS completed. Keeping AudioSession ACTIVE.");
              if (_useVoiceOutput == true && !_isTriageComplete) {
                debugPrint(
                    "Adding 150ms guard delay before starting listening...");
                await Future.delayed(const Duration(milliseconds: 150));
                debugPrint("Guard delay finished. Starting listening.");
                _startActualListening();
              } else {
                _updateState(SpeechServiceState.idle);
              }
            }
          },
          onError: (error) async {
            debugPrint('ElevenLabs player stream error: $error');
            await cancelPlaybackListeners();
            try {
              await _audioSession.setActive(false);
              debugPrint(
                  "Audio session deactivated due to player stream error.");
            } catch (e) {
              debugPrint("Error deactivating session on player error: $e");
            }
            _updateState(SpeechServiceState.idle);
          },
        );
        await _elevenLabsService.synthesizeAndPlay(textToSpeak);
      } else {
        // Flutter TTS
        await cancelPlaybackListeners();
        _flutterTts.setCompletionHandler(() async {
          await _audioSession.setActive(false);
          debugPrint("Audio session deactivated after FlutterTTS completion.");
          if (_useVoiceOutput == true && !_isTriageComplete) {
            _startActualListening();
          } else {
            _updateState(SpeechServiceState.idle);
          }
        });
        await _flutterTts.speak(textToSpeak);
      }
    } catch (e) {
      debugPrint('Error during TTS (_speak try block): $e');
      try {
        await _audioSession.setActive(false);
      } catch (sessionError) {
        debugPrint(
            "Error deactivating session in _speak catch block: $sessionError");
      }
      _updateState(SpeechServiceState.idle);
      _messagesController.add(
          Message(content: 'Error during speech synthesis: $e', isUser: false));
    }
  }

  Future<void> stopSpeaking() async {
    try {
      await _audioSession.setActive(false);
      debugPrint("Audio session deactivated due to stopSpeaking call.");
    } catch (e) {
      debugPrint("Error deactivating audio session in stopSpeaking: $e");
    }
    if (_ttsProvider == TTSProvider.elevenLabs) {
      await _elevenLabsService.stop();
    } else {
      await _flutterTts.stop();
    }
    _updateState(SpeechServiceState.idle);
  }

  void addTextMessage(String text) {
    if (text.trim().isEmpty) return;
    _useVoiceOutput ??= false;
    final userMessage = Message(content: text, isUser: true);
    _messages.add(userMessage);
    _messagesController.add(userMessage);
    if (!_isTriageComplete) {
      _getAIResponse();
    } else {
      debugPrint(
          'Triage already complete. Skipping AI response for text message.');
    }
  }

  void _updateState(SpeechServiceState newState) {
    _currentState = newState;
    _stateController.add(newState);
    debugPrint('SpeechService state changed to: $newState');
  }

  Future<List<Map<String, dynamic>>> getAvailableElevenLabsVoices() async {
    try {
      return await _elevenLabsService.getAvailableVoices();
    } catch (e) {
      debugPrint('Error fetching ElevenLabs voices via SpeechService: $e');
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> getAvailableElevenLabsModels() async {
    try {
      return await _elevenLabsService.getAvailableModels();
    } catch (e) {
      debugPrint('Error fetching ElevenLabs models via SpeechService: $e');
      return [];
    }
  }

  void setElevenLabsVoiceId(String voiceId) {
    _elevenLabsService.setVoiceId(voiceId);
    debugPrint('ElevenLabs voice ID set to: $voiceId via SpeechService');
  }

  void setElevenLabsModelId(String modelId) {
    _elevenLabsService.setModelId(modelId);
    debugPrint('ElevenLabs model ID set to: $modelId via SpeechService');
  }

  void setSystemPrompt(String prompt) {
    _systemPrompt = prompt;
    debugPrint('SpeechService system prompt updated.');
  }

  void dispose() {
    _speechController.close();
    _stateController.close();
    _messagesController.close();
    _speechToText.cancel();
    _flutterTts.stop();
    _elevenLabsService.dispose();
  }

  // Private method to start the actual speech recognition
  Future<void> _startActualListening() async {
    if (_isListening) return; // Prevent starting if already listening

    try {
      // Activate audio session for recording *before* starting listener
      await _audioSession.setActive(true);
      debugPrint("Audio session activated for listening.");
    } catch (e) {
      debugPrint("Error activating audio session for listening: $e");
      _updateState(
          SpeechServiceState.idle); // Go idle if session activation fails
      return; // Don't proceed
    }

    _updateState(SpeechServiceState.listening);
    _isListening = true;

    Message? partialMessage; // Placeholder message for partial results

    // --- Define SpeechListenOptions right before use ---
    final options = SpeechListenOptions(
      listenMode: ListenMode.dictation, // Correct way to set mode
      cancelOnError: true, // Recommended for robustness
      partialResults: true, // Keep partial results
      // Add other options if needed, e.g., autoPunctuation: true (iOS only)
    );

    // Note: listen itself doesn't return a future indicating completion.
    // Completion is handled via onResult or onStatus callbacks.
    _speechToText.listen(
      listenOptions: options, // Correct parameter name is listenOptions
      listenFor: const Duration(seconds: 15), // Duration outside options
      pauseFor: const Duration(seconds: 3), // Duration outside options
      localeId: 'en_US', // Locale outside options
      onResult: (result) {
        final text = result.recognizedWords;
        if (text.isEmpty) return; // Ignore empty results

        _speechController.add(text); // Send result to UI stream

        if (!result.finalResult) {
          // Handle partial result for real-time feedback
          debugPrint('Partial speech result: $text');
          if (partialMessage == null) {
            // Create new partial message if none exists
            partialMessage = Message(
              content: text,
              isUser: true,
              isPartial: true,
            );
            _messages.add(partialMessage!); // Add to history
            _messagesController.add(partialMessage!); // Update UI
          } else {
            // Update existing partial message
            partialMessage!.content = text;
            _messagesController.add(partialMessage!); // Update UI
          }
        } else {
          // Handle final result
          debugPrint('Final speech result: $text');
          if (partialMessage != null) {
            // Finalize existing partial message
            partialMessage!.content = text;
            partialMessage!.isPartial = false;
            _messagesController.add(partialMessage!); // Final UI update
          } else {
            // Create final message directly if no partial existed
            final finalMessage =
                Message(content: text, isUser: true, isPartial: false);
            _messages.add(finalMessage);
            _messagesController.add(finalMessage);
          }
          // Stop listening logically and process the AI response
          stopListening(); // This handles state and session deactivation
          _getAIResponse();
        }
      },
      // onStatus parameter removed from here - handled in initialize
    );
  }

  Future<void> startListening() async {
    _useVoiceOutput ??= true;
    await _startActualListening();
  }

  Future<void> stopListening() async {
    if (!_isListening) return;
    await _speechToText.stop();
    _isListening = false; // Update state immediately
    try {
      await _audioSession.setActive(false);
      debugPrint("Audio session deactivated after stopping listening.");
    } catch (e) {
      debugPrint(
          "Error deactivating audio session after stopping listening: $e");
    }
    if (_currentState == SpeechServiceState.listening && !_isTriageComplete) {
      _updateState(SpeechServiceState.processing);
    } else if (_currentState != SpeechServiceState.processing) {
      _updateState(SpeechServiceState.idle);
    }
  }

  Future<void> _getAIResponse() async {
    if (_isTriageComplete) {
      debugPrint('Triage already complete. Skipping AI response.');
      _updateState(SpeechServiceState.idle);
      return;
    }
    _updateState(SpeechServiceState.processing);
    await _getStreamingAIResponse();
  }

  Future<void> _getStreamingAIResponse() async {
    if (_openAiApiKey.isEmpty || _openAiApiKey == 'replace_with_your_key') {
      debugPrint(
          "OpenAI API Key is missing or invalid in _getStreamingAIResponse.");
      _messagesController
          .add(Message(content: "OpenAI API Key missing.", isUser: false));
      _updateState(SpeechServiceState.idle);
      return;
    }

    final List<OpenAIChatCompletionChoiceMessageModel> formattedMessages = [];
    formattedMessages.add(OpenAIChatCompletionChoiceMessageModel(
        role: OpenAIChatMessageRole.system,
        content: [
          OpenAIChatCompletionChoiceMessageContentItemModel.text(_systemPrompt)
        ]));
    formattedMessages.addAll(_messages
        .where((msg) => !msg.isPartial && msg.content.isNotEmpty)
        .map((msg) => OpenAIChatCompletionChoiceMessageModel(
                role: msg.isUser
                    ? OpenAIChatMessageRole.user
                    : OpenAIChatMessageRole.assistant,
                content: [
                  OpenAIChatCompletionChoiceMessageContentItemModel.text(
                      msg.content)
                ]))
        .toList());

    final pendingMessage = Message(content: "", isUser: false, isPartial: true);
    if (!_messages.any((m) => m.isPartial && !m.isUser)) {
      _messages.add(pendingMessage);
    }
    _messagesController.add(pendingMessage);

    debugPrint('Starting streaming OpenAI request using dart_openai');
    String fullContent = "";
    StreamSubscription<OpenAIStreamChatCompletionModel>? streamSubscription;

    try {
      final stream = OpenAI.instance.chat.createStream(
          model: "gpt-3.5-turbo", messages: formattedMessages, maxTokens: 150);
      streamSubscription = stream.listen(
        (event) {
          final deltaContent = event.choices.first.delta.content?.first?.text;
          if (deltaContent != null) {
            fullContent += deltaContent;
            final existingPending = _messages.firstWhere(
                (m) => m.isPartial && !m.isUser,
                orElse: () => pendingMessage);
            existingPending.content = fullContent;
            _messagesController.add(existingPending);
          }
        },
        onError: (error) {
          debugPrint("Error in OpenAI stream: $error");
          final existingPending = _messages.firstWhere(
              (m) => m.isPartial && !m.isUser,
              orElse: () => pendingMessage);
          if (_messages.contains(existingPending)) {
            _messages.remove(existingPending);
          }
          _messagesController.add(Message(
              content: "Error receiving AI response: $error", isUser: false));
          _updateState(SpeechServiceState.idle);
          streamSubscription?.cancel();
        },
        onDone: () async {
          debugPrint('OpenAI stream completed via dart_openai');
          final existingPending = _messages.firstWhere(
              (m) => m.isPartial && !m.isUser,
              orElse: () => pendingMessage);
          if (_messages.contains(existingPending)) {
            existingPending.isPartial = false;
            _messagesController.add(existingPending);
          }
          if (_useVoiceOutput == true && fullContent.isNotEmpty) {
            if (fullContent.contains("[TRIAGE_COMPLETE]")) {
              _isTriageComplete = true;
              debugPrint('TRIAGE_COMPLETE token detected in AI response.');
            }
            await _speak(fullContent);
          } else {
            if (fullContent.contains("[TRIAGE_COMPLETE]")) {
              _isTriageComplete = true;
              debugPrint(
                  'TRIAGE_COMPLETE token detected in AI response (text mode).');
            }
            _updateState(SpeechServiceState.idle);
          }
          streamSubscription?.cancel();
        },
        cancelOnError: true,
      );
    } catch (e) {
      debugPrint('Error creating OpenAI stream request: $e');
      final existingPending = _messages.firstWhere(
          (m) => m.isPartial && !m.isUser,
          orElse: () => pendingMessage);
      if (_messages.contains(existingPending)) {
        _messages.remove(existingPending);
      }
      _messagesController.add(
          Message(content: 'Error communicating with AI: $e', isUser: false));
      _updateState(SpeechServiceState.idle);
      await streamSubscription?.cancel();
    }
  }
}
