import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class WallpaperGradient {
  final String id;
  final String label;
  final List<Color> colors;

  const WallpaperGradient(this.id, this.label, this.colors);

  LinearGradient get gradient => LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors);
}

const wallpaperGradients = [
  WallpaperGradient('nebula', 'Nebula', [Color(0xFF0B0F2E), Color(0xFF3A1C71), Color(0xFF8E3C8C)]),
  WallpaperGradient('lagoon', 'Lagoon', [Color(0xFF031B2E), Color(0xFF04566E), Color(0xFF13A8A0)]),
  WallpaperGradient('ember', 'Ember', [Color(0xFF1C0A0C), Color(0xFF7A1F2B), Color(0xFFE06A3B)]),
  WallpaperGradient('moss', 'Moss', [Color(0xFF0A1711), Color(0xFF1E4D3A), Color(0xFF7A9A4E)]),
  WallpaperGradient('twilight', 'Twilight', [Color(0xFF111827), Color(0xFF2E3A66), Color(0xFF8A7BC8)]),
  WallpaperGradient('rosewood', 'Rosewood', [Color(0xFF1A0D18), Color(0xFF5B2245), Color(0xFFD06A8C)]),
  WallpaperGradient('glacier', 'Glacier', [Color(0xFF0C1726), Color(0xFF2B5C7E), Color(0xFFA3D2E0)]),
  WallpaperGradient('saffron', 'Saffron', [Color(0xFF1A1206), Color(0xFF6E3F0B), Color(0xFFE3A332)]),
  WallpaperGradient('citrus', 'Citrus', [Color(0xFF0E1A10), Color(0xFF3E6B1F), Color(0xFFD4C64A)]),
  WallpaperGradient('slate', 'Slate', [Color(0xFF0F1013), Color(0xFF2A2D35), Color(0xFF5A606C)]),
];

WallpaperGradient? wallpaperGradientById(String? id) {
  for (final gradient in wallpaperGradients) {
    if (gradient.id == id) return gradient;
  }
  return null;
}

class WallpaperChoice {
  static final ValueNotifier<Map<String, String?>> choices = ValueNotifier(const {});

  static String _key(String realm) => 'wallpaper_gradient_$realm';

  static Future<String?> load(String realm) async {
    final prefs = await SharedPreferences.getInstance();
    final id = wallpaperGradientById(prefs.getString(_key(realm)))?.id;
    if (choices.value[realm] != id || !choices.value.containsKey(realm)) {
      choices.value = {...choices.value, realm: id};
    }
    return id;
  }

  static Future<void> save(String realm, String? id) async {
    choices.value = {...choices.value, realm: id};
    final prefs = await SharedPreferences.getInstance();
    id == null ? await prefs.remove(_key(realm)) : await prefs.setString(_key(realm), id);
  }
}
