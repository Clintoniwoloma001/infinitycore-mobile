import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Wake words, mirroring `SARA_WAKE_WORDS` in
/// `infinitycore-sara/src/services/saraVoice.js`. Keeping one list means the
/// phone and the web respond to the same phrase.
const saraWakeWords = ['core', 'sara', 'assistant'];

/// One edit of slack is tolerated per token, so "sera" and "assistent" still
/// wake SARA. Mirrors `WAKE_WORD_MAX_DISTANCE` on the web.
const wakeWordMaxDistance = 1;

/// How long after a bare wake word SARA keeps listening for the command,
/// matching the web's ~6 second command window.
const commandWindow = Duration(milliseconds: 6000);

final _stopPhraseRe = RegExp(
  r'^(?:stop(?: listening)?|cancel(?: listening)?|never\s*mind|go to sleep|sleep)$',
  caseSensitive: false,
);

/// True when [text] is a phrase that should abort the current voice turn.
bool isSaraStopPhrase(String text) => _stopPhraseRe.hasMatch(text.trim());

/// A wake-word hit inside an utterance.
class SaraWakeMatch {
  const SaraWakeMatch(this.word, this.command);

  /// The canonical wake word that matched (not the mis-heard token).
  final String word;

  /// Everything after the wake word in the same utterance. Empty when the user
  /// only said the wake word, in which case SARA opens its listening window and
  /// waits for the command.
  final String command;
}

/// Finds a wake word in [transcript] and returns it with the command that
/// followed, or `null` when the phrase does not contain a wake word.
///
/// Matching is entirely local: the transcript is produced by the on-device
/// speech engine and compared here, so the app never streams microphone audio
/// anywhere just to decide whether the user said "SARA". Tokens are compared
/// with a Levenshtein tolerance of one edit, which is what lets the wake word
/// survive a single STT mis-hear.
SaraWakeMatch? findSaraWakeMatch(String transcript) {
  final text = transcript.trim();
  if (text.isEmpty) return null;
  for (final m in RegExp(r'[a-z0-9]+').allMatches(text.toLowerCase())) {
    final heard = m.group(0) ?? '';
    if (heard.isEmpty) continue;
    for (final candidate in saraWakeWords) {
      if (levenshtein(heard, candidate) <= wakeWordMaxDistance) {
        return SaraWakeMatch(candidate, _commandAfter(text, m.end));
      }
    }
  }
  return null;
}

/// Everything after the wake word, with a stop phrase stripped so
/// "hey SARA stop" does not open a listening window.
String _commandAfter(String text, int end) {
  final rest = text.substring(end).trim();
  if (rest.isEmpty) return '';
  if (isSaraStopPhrase(rest)) return '';
  // Speech-to-text routinely inserts a separator between the wake word and the
  // command ("SARA - show my leaves", "SARA, uh, show my leaves"). Strip any
  // leading run of punctuation and whitespace so the command is not submitted
  // with a dangling dash.
  return rest.replaceFirst(RegExp(r'^[\s,;:.!\-–—]+'), '').trim();
}

/// Classic Levenshtein edit distance.
///
/// [max] lets the hotword loop bail out early: a row whose best possible score
/// already exceeds [max] can never beat a match, and this runs on every interim
/// transcript.
int levenshtein(String a, String b, {int max = 1 << 20}) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var previous = List<int>.generate(b.length + 1, (i) => i);
  var current = List<int>.filled(b.length + 1, 0);
  for (var i = 0; i < a.length; i++) {
    current[0] = i + 1;
    var rowBest = current[0];
    for (var j = 0; j < b.length; j++) {
      final cost = a.codeUnitAt(i) == b.codeUnitAt(j) ? 0 : 1;
      current[j + 1] = math.min(
        math.min(current[j] + 1, previous[j + 1] + 1),
        previous[j] + cost,
      );
      if (current[j + 1] < rowBest) rowBest = current[j + 1];
    }
    if (rowBest > max) return rowBest;
    final swap = previous;
    previous = current;
    current = swap;
  }
  return previous[b.length];
}

/// Why the microphone is not available, so the UI can say something specific.
enum VoiceAvailability {
  ready,
  initialising,
  permissionDenied,
  unsupported,
  error;

  String get message => switch (this) {
    VoiceAvailability.ready => '',
    VoiceAvailability.initialising => 'Waking up the microphone…',
    VoiceAvailability.permissionDenied =>
      'Microphone access is off. Enable it in Settings to talk to SARA.',
    VoiceAvailability.unsupported =>
      'Voice input is not available on this device.',
    VoiceAvailability.error => 'The microphone could not be started.',
  };
}

/// SARA's speech layer: wake word, command capture and spoken replies.
///
/// Scope note — this runs while the app is in the foreground. Always-on hotword
/// listening with the app closed needs a native Android foreground service
/// (and the iOS background-audio entitlement), which is a new native release
/// rather than a Dart change. Everything here works today, and the wake-word
/// matcher is pure, so it can be reused verbatim inside that service later.
class SaraVoiceService with ChangeNotifier {
  SaraVoiceService._();
  static final SaraVoiceService instance = SaraVoiceService._();

  final SpeechToText _speech = SpeechToText();
  final FlutterTts _tts = FlutterTts();

  Timer? _commandTimer;

  /// Command captured after a wake word, awaiting submission to SARA.
  String? _pendingCommand;
  VoiceAvailability _availability = VoiceAvailability.initialising;

  bool _listening = false;
  bool _hotwordMode = true;
  bool _speaking = false;

  /// Emits whenever SARA is ready to answer something the user said.
  final ValueNotifier<String> command = ValueNotifier<String>('');

  VoiceAvailability get availability => _availability;

  /// Human-readable reason the microphone is unusable, or `null` when ready.
  String? get availabilityMessage {
    final m = _availability.message;
    return m.isEmpty ? null : m;
  }

  bool get isListening => _listening;

  bool get isHotwordMode => _hotwordMode;

  bool get isSpeaking => _speaking;

  /// Command captured but not yet sent, if any.
  String? get pendingCommand => _pendingCommand;

  bool get isSupported => _speech.isAvailable;

  /// Initialises the speech engine and asks for microphone permission.
  ///
  /// Safe to call repeatedly; the underlying plugin is idempotent.
  Future<VoiceAvailability> initialize() async {
    if (_availability == VoiceAvailability.ready) return _availability;
    _availability = VoiceAvailability.initialising;
    notifyListeners();
    try {
      final available = await _speech.initialize(
        onError: (e) => debugPrint('[SaraVoice] speech error: ${e.errorMsg}'),
        onStatus: (status) {
          // The platform stops listening on its own after a pause; reopen the
          // loop so the hotword keeps working for as long as the user wants.
          if (status == 'done' && _listening && _hotwordMode) {
            _restartListening();
          }
        },
        debugLogging: false,
      );
      if (!available) {
        // `lastStatus` carries the platform's reason ('notAuthorized',
        // 'denied', 'unsupported'…) and is the only signal available after a
        // failed `initialize`.
        final status = _speech.lastStatus;
        _availability = status == 'notAuthorized' || status == 'denied'
            ? VoiceAvailability.permissionDenied
            : VoiceAvailability.unsupported;
      } else {
        _availability = VoiceAvailability.ready;
        _configureTts();
      }
    } catch (e) {
      debugPrint('[SaraVoice] init failed: $e');
      _availability = VoiceAvailability.error;
    }
    notifyListeners();
    return _availability;
  }

  void _configureTts() {
    _tts.setStartHandler(() {
      _speaking = true;
      notifyListeners();
    });
    _tts.setCompletionHandler(() {
      _speaking = false;
      notifyListeners();
    });
    _tts.setCancelHandler(() {
      _speaking = false;
      notifyListeners();
    });
    _tts.setErrorHandler((_) {
      _speaking = false;
      notifyListeners();
    });
    unawaited(_tts.setSpeechRate(0.48));
    unawaited(_tts.setPitch(1.0));
    unawaited(_tts.setVolume(1.0));
  }

  /// Opens the microphone.
  ///
  /// With [hotword] true the listener stays open and only fires when a wake
  /// word is heard; with it false every final transcript is treated as a
  /// command, which is the push-to-talk path.
  Future<bool> startListening({bool hotword = true}) async {
    await initialize();
    if (_availability != VoiceAvailability.ready) return false;
    _hotwordMode = hotword;
    return _listenOnce();
  }

  Future<bool> _listenOnce() async {
    final ok = await _speech.listen(
      onResult: _onResult,
      listenOptions: SpeechListenOptions(
        // Dictation mode is how continuous listening is requested on Android.
        listenMode: ListenMode.dictation,
        partialResults: true,
        cancelOnError: false,
        listenFor: const Duration(minutes: 5),
        pauseFor: const Duration(seconds: 5),
      ),
    );
    if (ok) {
      _listening = true;
      notifyListeners();
    }
    return ok;
  }

  void _restartListening() {
    if (!_listening || !_hotwordMode) return;
    // A short delay lets the platform release the previous recogniser before
    // the next one is created; without it Android occasionally throws.
    Future<void>.delayed(const Duration(milliseconds: 250), () {
      if (_listening && _hotwordMode) _listenOnce();
    });
  }

  void _onResult(SpeechRecognitionResult result) {
    final text = result.recognizedWords;
    if (text.trim().isEmpty) return;

    if (!_hotwordMode) {
      command.value = text.trim();
      stopListening();
      return;
    }

    if (isSaraStopPhrase(text)) {
      _pendingCommand = null;
      _commandTimer?.cancel();
      stopListening();
      return;
    }

    final match = findSaraWakeMatch(text);
    if (match == null) return;

    _pendingCommand = match.command;
    _commandTimer?.cancel();
    // A bare wake word means "I'm listening" — hold the mic open for the rest
    // of the command window instead of dropping the user.
    _commandTimer = Timer(commandWindow, () => _pendingCommand = null);
    notifyListeners();

    if (match.command.isNotEmpty) {
      command.value = match.command;
      stopListening();
    }
  }

  void stopListening() {
    _commandTimer?.cancel();
    _commandTimer = null;
    _pendingCommand = null;
    if (_listening) {
      unawaited(_speech.cancel().catchError((Object _) => null));
      _listening = false;
      notifyListeners();
    }
  }

  /// Speaks [text], stopping any listening first so the recogniser does not
  /// transcribe SARA's own reply.
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    if (_listening) stopListening();
    try {
      await _tts.stop();
      await _tts.speak(text);
    } catch (e) {
      debugPrint('[SaraVoice] speak failed: $e');
    }
  }

  Future<void> stopSpeaking() async {
    try {
      await _tts.stop();
    } catch (_) {
      // Nothing to stop.
    }
    _speaking = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _commandTimer?.cancel();
    unawaited(_tts.stop().catchError((Object _) => null));
    super.dispose();
  }
}
