import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
// import '../config.dart'; // Config dependency removed for now

/// Service to handle text-to-speech using ElevenLabs API
class ElevenLabsService {
  // Configuration - to be injected
  late final String _apiKey;
  late final String _baseUrl;

  // Audio player for ElevenLabs audio
  final AudioPlayer _audioPlayer = AudioPlayer();

  // Track if audio is currently playing
  bool _isPlaying = false;

  // Voice ID to use (can be changed)
  String _voiceId;

  // Model ID to use (can be changed)
  String _modelId;

  // Constructor with configuration
  ElevenLabsService({
    required String apiKey,
    required String baseUrl,
    required String defaultVoiceId,
    required String defaultModelId,
  })  : _apiKey = apiKey,
        _baseUrl = baseUrl,
        _voiceId = defaultVoiceId,
        _modelId = defaultModelId;

  // Getter for playing status
  bool get isPlaying => _isPlaying;

  // Set voice ID
  void setVoiceId(String voiceId) {
    _voiceId = voiceId;
  }

  // Set model ID
  void setModelId(String modelId) {
    _modelId = modelId;
  }

  /// Initialize the service
  Future<void> initialize() async {
    // Set up completion handlers
    _audioPlayer.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        _isPlaying = false;
      }
    });

    // Initialize audio player without preloading
    try {
      // Try initializing with an empty source or a silent source if available
      // Using 'about:blank' might cause issues on some platforms
      await _audioPlayer.setAudioSource(
        AudioSource.uri(Uri.parse('')),
      ); // Use empty URI
    } catch (e) {
      debugPrint(
        'Error initializing audio player (can be ignored if playback works): $e',
      );
    }
  }

  /// Synthesize speech using ElevenLabs API and play the result
  Future<void> synthesizeAndPlay(String text) async {
    if (text.isEmpty) return;

    try {
      _isPlaying = true;
      debugPrint(
        'ElevenLabs: Synthesizing speech with voice ID: $_voiceId, model: $_modelId',
      );

      // Check if API key is available (already injected)
      if (_apiKey.isEmpty) {
        throw Exception(
          'ElevenLabs API key is missing. Ensure it is provided during service initialization.',
        );
      }

      // Make API request to ElevenLabs
      final url = Uri.parse(
        '$_baseUrl/text-to-speech/$_voiceId', // Use injected base URL
      );
      debugPrint('ElevenLabs: Making request to: $url');

      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json', 'xi-api-key': _apiKey},
        body: jsonEncode({
          'text': text,
          'model_id': _modelId,
          'voice_settings': {'stability': 0.5, 'similarity_boost': 0.75},
        }),
      );

      if (response.statusCode == 200) {
        debugPrint('ElevenLabs: Successfully received audio response');
        // Save audio bytes to a temporary file
        final tempDir = await getTemporaryDirectory();
        final file = File('${tempDir.path}/elevenlabs_audio.mp3');
        await file.writeAsBytes(response.bodyBytes);

        debugPrint('ElevenLabs: Saved audio to ${file.path}');

        // Play the audio
        await _audioPlayer.setFilePath(file.path);
        await _audioPlayer.play();
        debugPrint('ElevenLabs: Started playing audio');
      } else {
        // Handle error
        debugPrint('ElevenLabs API Error: ${response.statusCode}');
        debugPrint('Error body: ${response.body}');
        _isPlaying = false;
        throw Exception(
          'ElevenLabs API error: ${response.statusCode}\nBody: ${response.body}',
        );
      }
    } catch (e) {
      debugPrint('ElevenLabs synthesis error: $e');
      _isPlaying = false;
      rethrow; // Rethrow to let calling code handle the error
    }
  }

  /// Synthesize and stream audio (Note: Current implementation doesn't truly stream playback)
  /// This version downloads the full file first, then plays. True streaming requires
  /// a different API endpoint and audio player setup (e.g., using `StreamAudioSource`).
  Future<void> synthesizeAndStreamAudio(String text) async {
    if (text.isEmpty) return;

    try {
      _isPlaying = true;
      debugPrint(
        'ElevenLabs: Simulating stream (download then play) speech with voice ID: $_voiceId, model: $_modelId',
      );

      // Check if API key is available
      if (_apiKey.isEmpty) {
        throw Exception(
          'ElevenLabs API key is missing. Ensure it is provided during service initialization.',
        );
      }

      // Make the API request
      final url = Uri.parse(
        '$_baseUrl/text-to-speech/$_voiceId', // Use injected base URL
      );

      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json', 'xi-api-key': _apiKey},
        body: jsonEncode({
          'text': text,
          'model_id': _modelId,
          'voice_settings': {'stability': 0.5, 'similarity_boost': 0.75},
        }),
      );

      if (response.statusCode == 200) {
        // Get temp directory and create file path
        final tempDir = await getTemporaryDirectory();
        final file = File('${tempDir.path}/elevenlabs_stream_audio.mp3');

        // Write the audio file
        await file.writeAsBytes(response.bodyBytes);
        debugPrint('ElevenLabs: Audio downloaded to ${file.path}');

        // Set up the audio player
        await _audioPlayer.setAudioSource(
          AudioSource.uri(Uri.file(file.path)),
          preload: true,
        );
        debugPrint('ElevenLabs: Audio source set');

        // Start playback
        await _audioPlayer.play();
        debugPrint('ElevenLabs: Started playing audio');
      } else {
        debugPrint('ElevenLabs API Error: ${response.statusCode}');
        debugPrint('Error body: ${response.body}');
        _isPlaying = false;
        throw Exception(
          'ElevenLabs API error: ${response.statusCode}\nBody: ${response.body}',
        );
      }
    } catch (e) {
      debugPrint('ElevenLabs synthesis/stream error: $e');
      _isPlaying = false;
      rethrow;
    }
  }

  /// Stop speech playback
  Future<void> stop() async {
    if (_isPlaying) {
      await _audioPlayer.stop();
      _isPlaying = false;
      debugPrint('ElevenLabs: Playback stopped');
    }
  }

  /// Get available voices from ElevenLabs
  Future<List<Map<String, dynamic>>> getAvailableVoices() async {
    if (_apiKey.isEmpty) {
      debugPrint('Cannot get voices: ElevenLabs API key is missing.');
      return [];
    }
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/voices'), // Use injected base URL
        headers: {'Content-Type': 'application/json', 'xi-api-key': _apiKey},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return List<Map<String, dynamic>>.from(data['voices']);
      } else {
        debugPrint(
          'Error getting voices: ${response.statusCode} - ${response.body}',
        );
        return [];
      }
    } catch (e) {
      debugPrint('Exception getting voices: $e');
      return [];
    }
  }

  /// Get available models from ElevenLabs
  Future<List<Map<String, dynamic>>> getAvailableModels() async {
    if (_apiKey.isEmpty) {
      debugPrint('Cannot get models: ElevenLabs API key is missing.');
      return [];
    }
    try {
      debugPrint('ElevenLabs: Fetching available models');
      final response = await http.get(
        Uri.parse('$_baseUrl/models'), // Use injected base URL
        headers: {'Content-Type': 'application/json', 'xi-api-key': _apiKey},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        debugPrint('ElevenLabs: Models API response: ${response.body}');

        // Different parsing based on response structure
        if (data is List) {
          return List<Map<String, dynamic>>.from(data);
        }
        // Original code had handling for data['models'] and single object
        // Adjust if the API format requires different handling
        else if (data is Map &&
            data.containsKey('models') &&
            data['models'] is List) {
          return List<Map<String, dynamic>>.from(data['models']);
        } else if (data is Map) {
          // Assuming a single model object might be returned directly
          return [Map<String, dynamic>.from(data)];
        } else {
          debugPrint('Unexpected format for models response: $data');
          return [];
        }
      } else {
        debugPrint(
          'Error getting models: ${response.statusCode} - ${response.body}',
        );
        return []; // Don't return default model here, let caller handle empty list
      }
    } catch (e) {
      debugPrint('Exception getting models: $e');
      return [];
    }
  }

  /// Dispose resources
  void dispose() {
    _audioPlayer.dispose();
    debugPrint('ElevenLabsService disposed');
  }
}
