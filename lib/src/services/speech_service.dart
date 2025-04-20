import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'dart:io';
import '../models/message.dart'; // Correct path within the package
import 'elevenlabs_service.dart'; // Correct path within the package

enum SpeechServiceState { idle, listening, speaking, processing }

enum TTSProvider { flutterTTS, elevenLabs }

/// Service to handle voice-based communication with OpenAI
class SpeechService {
  // Configuration - to be injected later
  late final String _openAiApiKey;
  late final String _openAiChatUrl;

  // Speech recognition
  final SpeechToText _speechToText = SpeechToText();

  // Text-to-speech
  final FlutterTts _flutterTts = FlutterTts();

  // ElevenLabs service for natural voice
  late final ElevenLabsService _elevenLabsService; // Will be initialized later

  // TTS provider selection
  TTSProvider _ttsProvider = TTSProvider.elevenLabs;

  // State management
  bool _isListening = false;
  bool _isSpeaking = false;
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

  // Get current TTS provider
  TTSProvider get ttsProvider => _ttsProvider;

  // Set TTS provider
  set ttsProvider(TTSProvider provider) {
    _ttsProvider = provider;
  }

  // Constructor requires configuration
  SpeechService({
    required String openAiApiKey,
    required String openAiChatUrl,
    required ElevenLabsService elevenLabsService,
  }) {
    _openAiApiKey = openAiApiKey;
    _openAiChatUrl = openAiChatUrl;
    _elevenLabsService = elevenLabsService;
  }

  // Initialize speech services
  Future<void> initialize() async {
    // Initialize speech recognition
    bool available = await _speechToText.initialize();

    // Configure text-to-speech (Flutter TTS)
    await _flutterTts.setLanguage("en-US");
    await _flutterTts.setPitch(1.0);
    await _flutterTts.setSpeechRate(0.5);

    _flutterTts.setCompletionHandler(() {
      _isSpeaking = false;
      _updateState(SpeechServiceState.idle);
    });

    // Initialize ElevenLabs service (already injected)
    // await _elevenLabsService.initialize(); // Initialization handled by consuming app or main service setup

    // Log initialization status
    debugPrint(
      'Speech service initialized. Speech recognition available: $available',
    );
    debugPrint(
      'Using TTS provider: ${_ttsProvider == TTSProvider.elevenLabs ? "ElevenLabs" : "Flutter TTS"}',
    );

    if (!available) {
      debugPrint('Speech recognition not available');
    }
  }

  // Start listening to user speech
  Future<void> startListening() async {
    if (_isListening) return;

    _updateState(SpeechServiceState.listening);
    _isListening = true;

    // Create a placeholder message for partial results
    Message? partialMessage;

    await _speechToText.listen(
      onResult: (result) {
        final text = result.recognizedWords;

        if (text.isEmpty) return;

        // Always send the current recognition text to the speech controller
        _speechController.add(text);

        if (!result.finalResult) {
          // Handle partial result for real-time feedback
          debugPrint('Partial speech result: $text');

          // Update or create partial message
          if (partialMessage == null) {
            partialMessage = Message(
              content: text,
              isUser: true,
              isPartial: true,
            );
            _messages.add(partialMessage!);
            _messagesController.add(partialMessage!);
          } else {
            // Update existing partial message
            partialMessage!.content = text;
            _messagesController.add(partialMessage!);
          }
        } else {
          // Final result - remove partial message if it exists
          if (partialMessage != null) {
            _messages.remove(partialMessage);
          }

          // Add final user message to history
          final message = Message(content: text, isUser: true);
          _messages.add(message);
          _messagesController.add(message);

          // Stop listening and process response
          stopListening();
          _getAIResponse();
        }
      },
      listenFor: const Duration(seconds: 15),
      pauseFor: const Duration(seconds: 3),
      localeId: 'en_US',
      listenMode: ListenMode.dictation, // Better for continuous speech
    );
  }

  // Stop listening to user speech
  Future<void> stopListening() async {
    if (!_isListening) return;

    await _speechToText.stop();
    _isListening = false;

    if (_currentState == SpeechServiceState.listening) {
      _updateState(SpeechServiceState.processing);
    }
  }

  // Get AI response based on conversation history
  Future<void> _getAIResponse() async {
    _updateState(SpeechServiceState.processing);

    // Try using streaming response
    await _getStreamingAIResponse();
  }

  // Get streaming AI response using SSE
  Future<void> _getStreamingAIResponse() async {
    try {
      // Prepare messages for API call
      final List<Map<String, dynamic>> formattedMessages =
          _messages.map((msg) => msg.toJson()).toList();

      // Remove any partial messages before sending
      formattedMessages.removeWhere(
        (msg) => msg['content'].isEmpty || msg['content'] == null,
      );

      // Create placeholder message for streaming responses
      final pendingMessage = Message(
        content: "",
        isUser: false,
        isPartial: true,
      );
      _messages.add(pendingMessage);
      _messagesController.add(pendingMessage);

      debugPrint('Starting streaming OpenAI request');

      // Use HTTP client with streaming capability
      final client = HttpClient();
      final request = await client.postUrl(
        Uri.parse(_openAiChatUrl),
      ); // Use injected URL

      // Add request headers
      request.headers.set('Content-Type', 'application/json');
      request.headers.set(
        'Authorization',
        'Bearer $_openAiApiKey',
      ); // Use injected key

      // Prepare request body with streaming flag
      final requestBody = jsonEncode({
        'model': 'gpt-3.5-turbo',
        'messages': [
          {
            'role': 'system',
            'content':
                'You are a helpful AI assistant. Please keep your responses concise and to the point. Aim for 1-2 sentences when possible.',
          },
          ...formattedMessages,
        ],
        'stream': true,
        'max_tokens': 150, // Limit response length
      });

      request.write(requestBody);
      final response = await request.close();

      if (response.statusCode == 200) {
        debugPrint('Receiving OpenAI streaming response');

        String fullContent = "";

        // Process the streaming response
        await for (var data in response.transform(utf8.decoder)) {
          // Handle SSE format (each line starts with "data: ")
          final lines = data.split('\n');

          for (var line in lines) {
            if (line.startsWith('data: ') && line != 'data: [DONE]') {
              String jsonData = ''; // Initialize outside try-catch
              try {
                // Extract the actual JSON data part
                jsonData = line.substring(6);

                // Parse the JSON response
                final Map<String, dynamic> chunk = jsonDecode(jsonData);

                // Extract incremental text (delta)
                final delta = chunk['choices'][0]['delta']['content'] ?? '';
                fullContent += delta;

                // Update our pending message with accumulated content
                pendingMessage.content = fullContent;
                _messagesController.add(pendingMessage);
              } catch (e) {
                // Log error for the specific chunk but continue processing
                debugPrint('Error parsing stream chunk: $e');
                debugPrint('Problematic JSON data: $jsonData');
              }
            } else if (line == 'data: [DONE]') {
              // Stream finished
              debugPrint('OpenAI stream completed');
              // Finalize the message (mark as not partial)
              pendingMessage.isPartial = false;
              _messagesController.add(pendingMessage);
              if (fullContent.isNotEmpty) {
                _speak(fullContent);
              }
              client.close(); // Ensure the client is closed when done
              return; // Exit the method after completion
            }
          }
        }
        // Should close client if loop finishes unexpectedly (e.g., connection drop)
        client.close();
      } else {
        // Handle error
        debugPrint('OpenAI API Error: ${response.statusCode}');
        String responseBody = await response.transform(utf8.decoder).join();
        debugPrint('Error body: $responseBody');

        // Remove pending message on error
        _messages.remove(pendingMessage);
        _messagesController.add(
          Message(
            content: 'Error: ${response.statusCode} - $responseBody',
            isUser: false,
          ),
        );
        _updateState(SpeechServiceState.idle);
        client.close(); // Ensure client is closed on error
      }
    } catch (e) {
      debugPrint('Error getting AI response: $e');
      _messagesController.add(
        Message(content: 'Error communicating with AI: $e', isUser: false),
      );
      _updateState(SpeechServiceState.idle);
    } finally {
      // Ensure state returns to idle unless speaking starts
      if (_currentState != SpeechServiceState.speaking) {
        _updateState(SpeechServiceState.idle);
      }
    }
  }

  // Speak the given text using the selected TTS provider
  Future<void> _speak(String text) async {
    if (text.isEmpty) {
      _updateState(SpeechServiceState.idle);
      return;
    }

    _updateState(SpeechServiceState.speaking);
    _isSpeaking = true;

    try {
      if (_ttsProvider == TTSProvider.elevenLabs) {
        // Use ElevenLabs service
        await _elevenLabsService.synthesizeAndPlay(text);
        // Rely on ElevenLabsService's internal state/completion to set _isSpeaking = false
      } else {
        // Use Flutter TTS
        await _flutterTts.speak(text);
        // Completion handler for FlutterTTS will set _isSpeaking = false
      }
    } catch (e) {
      debugPrint('Error during TTS: $e');
      _isSpeaking = false;
      _updateState(SpeechServiceState.idle);
      // Optionally add an error message to the chat
      _messagesController.add(
        Message(content: 'Error during speech synthesis: $e', isUser: false),
      );
    } finally {
      // Ensure state transitions correctly if speaking finishes quickly or errors out
      // The completion handlers/listeners should handle the final state change
      // but this is a safeguard.
      // We might need a better way to know when ElevenLabs is truly done.
      // Let's wait for the completion handler logic for now.
    }
  }

  // Stop speech playback
  Future<void> stopSpeaking() async {
    if (_ttsProvider == TTSProvider.elevenLabs) {
      await _elevenLabsService.stop();
    } else {
      await _flutterTts.stop();
    }
    _isSpeaking = false;
    _updateState(SpeechServiceState.idle);
  }

  // Add a text message (e.g., from a text input field)
  void addTextMessage(String text) {
    if (text.trim().isEmpty) return;

    // Add user message
    final userMessage = Message(content: text, isUser: true);
    _messages.add(userMessage);
    _messagesController.add(userMessage);

    // Get AI response
    _getAIResponse();
  }

  // Update the current state and notify listeners
  void _updateState(SpeechServiceState newState) {
    _currentState = newState;
    _stateController.add(newState);
    debugPrint('SpeechService state changed to: $newState');
  }

  // --- ElevenLabs Settings Proxy Methods ---

  /// Gets the list of available voices from the configured ElevenLabs service.
  /// Returns an empty list if the API key is missing or an error occurs.
  Future<List<Map<String, dynamic>>> getAvailableElevenLabsVoices() async {
    // Ensure ElevenLabs is the selected provider, although fetching might be okay regardless
    // if (_ttsProvider != TTSProvider.elevenLabs) return [];
    try {
      return await _elevenLabsService.getAvailableVoices();
    } catch (e) {
      debugPrint('Error fetching ElevenLabs voices via SpeechService: $e');
      return [];
    }
  }

  /// Gets the list of available models from the configured ElevenLabs service.
  /// Returns an empty list if the API key is missing or an error occurs.
  Future<List<Map<String, dynamic>>> getAvailableElevenLabsModels() async {
    try {
      return await _elevenLabsService.getAvailableModels();
    } catch (e) {
      debugPrint('Error fetching ElevenLabs models via SpeechService: $e');
      return [];
    }
  }

  /// Sets the voice ID to be used by the underlying ElevenLabs service.
  void setElevenLabsVoiceId(String voiceId) {
    _elevenLabsService.setVoiceId(voiceId);
    debugPrint('ElevenLabs voice ID set to: $voiceId via SpeechService');
    // Note: No notifyListeners() here, this service doesn't use ChangeNotifier
  }

  /// Sets the model ID to be used by the underlying ElevenLabs service.
  void setElevenLabsModelId(String modelId) {
    _elevenLabsService.setModelId(modelId);
    debugPrint('ElevenLabs model ID set to: $modelId via SpeechService');
  }

  // --- End of ElevenLabs Settings Proxy Methods ---

  // Dispose resources
  void dispose() {
    _speechController.close();
    _stateController.close();
    _messagesController.close();
    _speechToText.cancel();
    _flutterTts.stop();
    _elevenLabsService.dispose(); // Dispose injected service
  }
}
