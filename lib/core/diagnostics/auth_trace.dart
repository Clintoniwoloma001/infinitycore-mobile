/// Timestamped trace of the authentication / routing state machine.
///
/// Uses `print` rather than `debugPrint` on purpose: `print` still reaches
/// `adb logcat` (tag `flutter`) from a RELEASE build, and release timing
/// differs from debug — the login bounce-back race can only be disproved on a
/// release build, so the trace has to survive release compilation.
///
/// Every line is prefixed with `AUTH_TRACE` so a capture can be isolated with:
///
/// ```
/// adb logcat -c && adb shell am start ... && adb logcat | grep AUTH_TRACE
/// ```
class AuthTrace {
  AuthTrace._();

  /// Milliseconds since process start. Intra-launch ordering is then
  /// unambiguous regardless of the logcat timestamp format of the ADB version
  /// in use.
  static final Stopwatch _since = Stopwatch()..start();

  static int _pipelineSeq = 0;

  /// Monotonic id so concurrent settle pipelines are distinguishable in the
  /// log instead of looking like one interleaved blur.
  static int nextPipelineId() => ++_pipelineSeq;

  static void log(String tag, String message) {
    final ms = _since.elapsedMilliseconds.toString().padLeft(6, '0');
    // ignore: avoid_print
    print('AUTH_TRACE t=+${ms}ms [$tag] $message');
  }
}
