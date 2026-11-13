import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class EditorSession {
  final String? folder;
  final List<String> paths;
  final int active;

  const EditorSession({this.folder, this.paths = const [], this.active = 0});

  bool get isEmpty => folder == null && paths.isEmpty;
}

class EditorSessionStore {
  static String _key(String realm) => 'editor_session_$realm';

  static Future<EditorSession?> load(String realm) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(realm));
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return EditorSession(
        folder: json['folder'] as String?,
        paths: [
          for (final path in json['paths'] as List? ?? const [])
            if (path is String) path,
        ],
        active: json['active'] as int? ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(String realm, EditorSession session) async {
    final prefs = await SharedPreferences.getInstance();
    if (session.isEmpty) {
      await prefs.remove(_key(realm));
      return;
    }
    await prefs.setString(
      _key(realm),
      jsonEncode({'folder': session.folder, 'paths': session.paths, 'active': session.active}),
    );
  }
}
