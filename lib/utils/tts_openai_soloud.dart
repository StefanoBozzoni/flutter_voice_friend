// lib/utils/tts_openai_soloud.dart

import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:http/http.dart' as http;
import 'dart:async';
import 'dart:collection';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'dart:io';
import 'package:flutter_voice_friend/config.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:uuid/uuid.dart';
import 'package:flutter_voice_friend/utils/tts_openai_interface.dart'
    as tts_interface;

// Initialize SoLoud instance
final soloud = SoLoud.instance;

// Function to extract asset
Future<String> extractAsset(String assetName) async {
  final byteData = await rootBundle.load("assets/sounds/$assetName");
  final directory = await getTemporaryDirectory();
  final filePath = '${directory.path}/$assetName';
  final file = File(filePath);
  await file.writeAsBytes(byteData.buffer
      .asUint8List(byteData.offsetInBytes, byteData.lengthInBytes));
  return filePath;
}

class TextToSpeechOpenAI implements tts_interface.TextToSpeechOpenAI {
  final soloud = SoLoud.instance;
  final Queue<String> _queue = Queue<String>();
  bool _hasAudioToPlay = false;
  bool _isPlayingAudio = false;

  // AudioData manages audio samples in version 4.x
  AudioData? _audioSamples;

  final bool debug = true;
  final Queue<Future<String>> _audioBuffer = Queue<Future<String>>();
  final Queue<String> _textBuffer = Queue<String>();

  String _currentSubtitles = "";
  double _currentIntensity = 0;
  final int _maxCharacters = 200;
  double _voiceSpeed = 1.0;

  bool _autoPause = false;
  bool _waitForNext = false;
  bool _repeat = false;
  String _voice;
  final Uuid _uuid = const Uuid();
  late Directory _tempDirectoryForAudioFiles;
  Timer? _audioIntensityTimer;

  int _timePlayedInMs = 0;

  final StreamController<Exception> _errorController =
      StreamController<Exception>.broadcast();

  @override
  Stream<Exception> get errorStream => _errorController.stream;

  TextToSpeechOpenAI(this._voice) {
    _initializeTempDirectory();
  }

  @override
  Future<void> initializePlayer() async {
    debugPrint("initialize Soloud library");
    if (!soloud.isInitialized) {
      await soloud.init();
    }
    soloud.setVisualizationEnabled(true);
    soloud.setGlobalVolume(1);
    soloud.setMaxActiveVoiceCount(32);
    
    // In version 4.x, we must instantiate AudioData to get samples
    _audioSamples ??= AudioData(GetSamplesKind.wave);
  }

  @override
  void deinitializePlayer() {
    if (soloud.isInitialized) {
      _audioIntensityTimer?.cancel();
      _audioSamples?.dispose();
      _audioSamples = null;
      soloud.deinit();
    }
  }

  Future<void> reinitPlayer() async {
    deinitializePlayer();
    await initializePlayer();
  }

  Future<void> _initializeTempDirectory() async {
    try {
      final tempDir = await getTemporaryDirectory();
      _tempDirectoryForAudioFiles = Directory('${tempDir.path}/tts_audio');
      await _cleanupTempDirectory();
      await _tempDirectoryForAudioFiles.create();
    } catch (e) {
      _handleError(Exception('Failed to initialize temp directory: $e'));
    }
  }

  Future<void> _cleanupTempDirectory() async {
    try {
      if (await _tempDirectoryForAudioFiles.exists()) {
        await _tempDirectoryForAudioFiles.delete(recursive: true);
      }
    } catch (e) {
      debugPrint('Failed to clean up temp directory: $e');
    }
  }

  @override
  void setVoiceSpeed(double voiceSpeed) {
    _voiceSpeed = voiceSpeed;
  }

  void _startAudioDataFetch() {
    _audioIntensityTimer?.cancel();
    _audioIntensityTimer =
        Timer.periodic(const Duration(milliseconds: 100), (timer) {
      if (!_isPlayingAudio || _audioSamples == null) {
        timer.cancel();
        return;
      }
      
      try {
        // Step 1: Capture current samples
        _audioSamples!.updateSamples();
        // Step 2: Get the captured samples as Float32List
        final waveData = _audioSamples!.getAudioData();
        
        double a = 0;
        for (var i = 0; i < 10 && i < waveData.length; i++) {
          a += waveData[i].abs();
        }
        _currentIntensity = a;
      } catch (e) {
        debugPrint("Error fetching audio samples: $e");
      }
    });
  }

  @override
  double getCurrentIntensity() {
    return _currentIntensity;
  }

  @override
  void updateVoice(String voice) {
    _voice = voice;
  }

  @override
  void dispose() {
    try {
      _audioIntensityTimer?.cancel();
      _audioSamples?.dispose();
      _audioSamples = null;
      soloud.deinit();
      _cleanupTempDirectory();
      _errorController.close();
    } catch (e) {
      debugPrint('Error during dispose: $e');
    }
  }

  @override
  bool isPlaying() {
    return _isPlayingAudio;
  }

  @override
  bool hasAudioToPlay() {
    return _hasAudioToPlay;
  }

  @override
  void toggleAutoPause() {
    _autoPause = !_autoPause;
    _waitForNext = _autoPause;
  }

  @override
  void repeat() {
    _repeat = true;
  }

  @override
  void next() {
    _waitForNext = false;
  }

  @override
  bool lastAudioToPlay() {
    return _audioBuffer.isEmpty;
  }

  @override
  void stop() async {
    _isPlayingAudio = false;
    _audioIntensityTimer?.cancel();
    if (soloud.isInitialized) await soloud.disposeAllSources();
    _audioBuffer.clear();
    _textBuffer.clear();
    _queue.clear();
    _hasAudioToPlay = false;
    _currentSubtitles = "";
    _waitForNext = false;
    _repeat = false;
    _autoPause = false;
  }

  @override
  Future<void> playTextToSpeech(String text) async {
    _queue.add(text);
    _processQueue(maxCharacters: _maxCharacters);
  }

  void _addSentenceWithPauses(String text) async {
    try {
      text = text.replaceAll("[END]", "");
      List<String> chunks = text.split("[pause]");
      var numberOfConsecutivePause = 0;
      for (String chunk in chunks) {
        if (chunk.trim().isNotEmpty) {
          numberOfConsecutivePause = 0;
          _audioBuffer.add(_synthesizeAndBuffer(chunk));
          _textBuffer.add(chunk);
        }
        numberOfConsecutivePause++;
        _audioBuffer.add(Future.value("pause"));
        _textBuffer.add(" . " * numberOfConsecutivePause);
      }
      if (chunks.isNotEmpty) {
        _audioBuffer.removeLast();
        _textBuffer.removeLast();
      }
    } catch (e) {
      _handleError(Exception('Error adding sentences with pauses: $e'));
    }
  }

  void _processQueue({required int maxCharacters}) async {
    if (_audioBuffer.length > 1) return;
    while (_queue.isNotEmpty && _audioBuffer.length < 2) {
      try {
        int currentLength = 0;
        List<String> segmentsToPlay = [];
        while (_queue.isNotEmpty && currentLength <= maxCharacters) {
          String segment = _queue.removeFirst();
          segmentsToPlay.add(segment);
          currentLength += segment.length;
        }
        String concatenatedText = segmentsToPlay.join(' ').trim();
        if (concatenatedText.length >= 5) {
          _addSentenceWithPauses(concatenatedText);
        }
        if (_queue.isEmpty) break;
      } catch (e) {
        _handleError(Exception('Error processing queue: $e'));
      }
    }
    if (!_hasAudioToPlay) {
      _playBufferedSegments();
    }
  }

  Future<String> _synthesizeAndBuffer(String text) async {
    try {
      return await _synthesizeAudio(text);
    } catch (e) {
      _handleError(Exception('Error synthesizing and buffering: $e'));
      return '';
    }
  }

  @override
  String getSubtitles() {
    return _currentSubtitles;
  }

  Future<void> _playBufferedSegments() async {
    _hasAudioToPlay = true;
    if (!soloud.isInitialized) {
      await initializePlayer();
    }

    bool isFirstSentence = true;

    while (_audioBuffer.isNotEmpty) {
      final segmentPath = await _audioBuffer.removeFirst();
      String currentSentence = _textBuffer.removeFirst();

      if (segmentPath.isNotEmpty) {
        _isPlayingAudio = true;
        if (!isFirstSentence) {
          await Future.delayed(const Duration(milliseconds: 300));
        }

        if (segmentPath == "pause") {
          if (!_autoPause) {
            await Future.delayed(const Duration(milliseconds: 1500));
          }
        } else {
          try {
            await soloud.disposeAllSources();
            final source = await soloud.loadFile(segmentPath);
            
            // In 4.x play() is synchronous
            final handle = soloud.play(source);
            soloud.setRelativePlaySpeed(handle, _voiceSpeed);
            
            _startAudioDataFetch();

            currentSentence = currentSentence.replaceAll('\n', ' ').trim();
            if (currentSentence.length > 8) {
              _currentSubtitles = currentSentence;
            }

            _timePlayedInMs = 0;
            while (soloud.getIsValidVoiceHandle(handle)) {
              _timePlayedInMs += 100;
              await Future.delayed(const Duration(milliseconds: 100));
              if (_timePlayedInMs > 20000 && _autoPause) break;
            }

            await soloud.stop(handle);
            await soloud.disposeSource(source);

            if (_autoPause) {
              _isPlayingAudio = false;
              _waitForNext = true;
              while (_waitForNext) {
                await Future.delayed(const Duration(milliseconds: 100));
                if (_repeat) {
                  _isPlayingAudio = true;
                  _waitForNext = false;
                  final source = await soloud.loadFile(segmentPath);
                  final handle = soloud.play(source);
                  soloud.setRelativePlaySpeed(handle, _voiceSpeed);
                  _startAudioDataFetch();
                  _timePlayedInMs = 0;
                  while (soloud.getIsValidVoiceHandle(handle)) {
                    _timePlayedInMs += 100;
                    await Future.delayed(const Duration(milliseconds: 100));
                    if (_timePlayedInMs > 20000) break;
                  }
                  await soloud.stop(handle);
                  await soloud.disposeSource(source);
                  _repeat = false;
                  _isPlayingAudio = false;
                  _waitForNext = true;
                }
              }
            }
          } catch (e) {
            _handleError(Exception('Error playing audio: $e'));
          }
        }
      }
      isFirstSentence = false;
      if (_audioBuffer.length <= 2) _processQueue(maxCharacters: _maxCharacters);
    }
    _hasAudioToPlay = false;
    _isPlayingAudio = false;
  }

  Future<String> _synthesizeAudio(String text) async {
    final response = await http.post(
      Uri.parse(Config.openaiTtsUrl),
      headers: {
        'Authorization': 'Bearer ${Config.openaiApiKey}',
        'Content-Type': 'application/json',
      },
      body: json.encode({
        "model": "tts-1",
        "input": text,
        "voice": _voice,
        "response_format": "wav"
      }),
    );

    if (response.statusCode == 200) {
      final uniqueFilename = _uuid.v4();
      final filePath = path.join(_tempDirectoryForAudioFiles.path, '$uniqueFilename.wav');
      final file = File(filePath);
      await file.writeAsBytes(response.bodyBytes);
      return filePath;
    } else {
      throw Exception('Failed to synthesize audio');
    }
  }

  void _handleError(Exception e) {
    stop();
    if (!_errorController.isClosed) _errorController.add(e);
  }
}
