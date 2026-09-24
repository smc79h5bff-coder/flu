import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 全局的 SharedPreferences 实例。
/// 在 main() 里通过 `ProviderScope.overrides` 注入真实实例。
/// 任何地方想读 prefs，就 `ref.read(sharedPreferencesProvider)`。
final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError(
    'sharedPreferencesProvider 必须在 main() 里 override。',
  );
});
