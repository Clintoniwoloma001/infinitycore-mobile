import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// App-wide theme mode (light / dark / system) with persistence.
///
/// The stored value is a plain preference string — not a secret — but the app
/// already maps the secure storage plugin, so the same, well-tested surface is
/// reused rather than introducing a second storage dependency.
class ThemeController extends ChangeNotifier {
  ThemeController._();

  static final ThemeController instance = ThemeController._();

  static const _storage = FlutterSecureStorage();
  static const _key = 'infinitycore.theme_mode';

  ThemeMode _mode = ThemeMode.system;

  ThemeMode get mode => _mode;

  bool get isDark => _mode == ThemeMode.dark;

  Future<void> load() async {
    try {
      final v = await _storage.read(key: _key);
      _mode = switch (v) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
    } catch (_) {
      _mode = ThemeMode.system;
    }
    notifyListeners();
  }

  Future<void> setMode(ThemeMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    notifyListeners();
    try {
      await _storage.write(key: _key, value: mode.name);
    } catch (_) {
      // Persistence is best-effort; the in-memory mode still applies.
    }
  }
}
