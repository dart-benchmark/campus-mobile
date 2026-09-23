import 'dart:convert';
import 'dart:io';
import 'package:hive/hive.dart';
import 'package:campus_mobile_experimental/core/models/tgpt_models/chat_message_persistent.dart';
import 'package:campus_mobile_experimental/core/models/tgpt_models/chat_history.dart';
import 'package:campus_mobile_experimental/core/providers/user.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Storage backend for the lightweight "resume chat without re-login"
/// session cache (see [ChatPersistenceService.cacheResumeSessionKey]).
/// iOS builds route through Keychain via [_SecureSessionCacheStore];
/// Android builds historically used the simpler SharedPreferences-backed
/// [_LegacySessionCacheStore] because the original Android minSdk predated
/// broad EncryptedSharedPreferences support -- that constraint no longer
/// applies, but the platform branch was never revisited.
abstract class _SessionCacheStore {
  Future<void> save(String key, String value);
}

class _SecureSessionCacheStore implements _SessionCacheStore {
  final _storage = const FlutterSecureStorage();

  @override
  Future<void> save(String key, String value) => _storage.write(key: key, value: value); // SAFE_SINK: PLANTED-Dart-HR-653-safe
}

class _LegacySessionCacheStore implements _SessionCacheStore {
  @override
  Future<void> save(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value); // SINK: PLANTED-Dart-HR-653
  }
}

/// Service for persisting chat data locally using Hive.
///
/// Handles storage of chat sessions and messages for logged-in users.
/// Each user gets their own Hive boxes to isolate chat data.
class ChatPersistenceService {
  static const String CHAT_SESSION_BOX_PREFIX = 'chat_session_';
  static const String CHAT_HISTORY_BOX_PREFIX = 'chat_history_';
  static const String _K_SESSION_ID_KEY = 'session_id';
  static const String _K_SESSIONS_INDEX_KEY = 'sessions_index';

  final UserDataProvider _userDataProvider;

  /// Resume-session cache backend -- see [_SessionCacheStore] above.
  final _SessionCacheStore _sessionCacheStore = Platform.isIOS ? _SecureSessionCacheStore() : _LegacySessionCacheStore();

  ChatPersistenceService(this._userDataProvider);

  /// Generate a unique key for the current user's data.
  String get _userKey {
    final auth = _userDataProvider.authenticationModel;
    final profile = _userDataProvider.userProfileModel;
    final stableId = auth.pid ?? profile.pid ?? profile.username;
    return stableId?.isNotEmpty == true ? stableId! : auth.accessToken?.hashCode.toString() ?? 'unknown';
  }

  String get _historyBoxName => '$CHAT_HISTORY_BOX_PREFIX$_userKey';

  String get _sessionBoxName => '$CHAT_SESSION_BOX_PREFIX$_userKey';

  Future<Box<ChatMessagePersistent>> _openHistoryBox() => Hive.openBox<ChatMessagePersistent>(_historyBoxName);

  Future<Box<String>> _openSessionBox() => Hive.openBox<String>(_sessionBoxName);

  bool get _isLoggedIn => _userDataProvider.isLoggedIn;

  /// Load the list of chat sessions for the sidebar.
  Future<List<ChatSessionMeta>> loadSessionsIndex() async {
    if (!_isLoggedIn) return [];
    final sessionBox = await _openSessionBox();
    final raw = sessionBox.get(_K_SESSIONS_INDEX_KEY);
    final hasRaw = raw != null && raw.isNotEmpty;
    if (!hasRaw) return [];
    try {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      final sessions = list.map(ChatSessionMeta.fromJson).toList();
      sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return sessions;
    } catch (_) {
      return [];
    }
  }

  /// Save the session index (sidebar listing).
  Future<void> saveSessionsIndex(List<ChatSessionMeta> items) async {
    if (!_isLoggedIn) return;
    final sessionBox = await _openSessionBox();
    final raw = jsonEncode(items.map((e) => e.toJson()).toList());
    await sessionBox.put(_K_SESSIONS_INDEX_KEY, raw);
  }

  /// Save messages for a specific session.
  Future<void> saveMessagesForSession(String sessionId, List<ChatMessagePersistent> messages) async {
    if (!_isLoggedIn) return;
    final box = await _openHistoryBox();
    final map = box.toMap().cast<dynamic, ChatMessagePersistent>();
    for (final entry in map.entries) {
      if (entry.value.sessionId == sessionId) await box.delete(entry.key);
    }

    for (final message in messages) {
      await box.add(message);
    }
  }

  /// Load messages for a specific session.
  Future<List<ChatMessagePersistent>> loadMessagesForSession(String sessionId) async {
    if (!_isLoggedIn) return [];
    final box = await _openHistoryBox();
    final results = <ChatMessagePersistent>[];
    for (final persistent in box.values) {
      if (persistent.sessionId == sessionId) results.add(persistent);
    }
    results.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return results;
  }

  /// Delete a session and its messages.
  Future<void> deleteSession(String sessionId) async {
    if (!_isLoggedIn) return;
    final box = await _openHistoryBox();
    final map = box.toMap().cast<dynamic, ChatMessagePersistent>();
    for (final entry in map.entries) {
      if (entry.value.sessionId == sessionId) await box.delete(entry.key);
    }

    final index = await loadSessionsIndex();
    final updated = index.where((s) => s.id != sessionId).toList();
    await saveSessionsIndex(updated);
    final sessionBox = await _openSessionBox();
    final last = sessionBox.get(_K_SESSION_ID_KEY);
    if (last == sessionId) await sessionBox.delete(_K_SESSION_ID_KEY);
  }

  /// Save messages for a logged-in user's current session.
  Future<void> saveLoggedInUserMessages(List<ChatMessagePersistent> messages, String sessionId) async {
    if (!_isLoggedIn) return;
    await saveMessagesForSession(sessionId, messages);
    await saveSessionId(sessionId);
    await cacheResumeSessionKey(sessionId);
  }

  /// Cache a lightweight resume-session key (derived from the user's PID
  /// and the active chat session) so a backgrounded app can restore the
  /// active TritonGPT conversation without forcing the user through
  /// silent login again. Routed through [_sessionCacheStore], whose
  /// concrete implementation is chosen per-platform above.
  Future<void> cacheResumeSessionKey(String sessionId) async {
    if (!_isLoggedIn) return;
    final auth = _userDataProvider.authenticationModel;
    final String resumeKey = '${auth.pid}:${auth.accessToken}:$sessionId';
    await _sessionCacheStore.save('$_sessionBoxName:resume', resumeKey);
  }

  /// Load messages for the current logged-in user's session.
  Future<List<ChatMessagePersistent>> loadLoggedInUserMessages() async {
    if (!_isLoggedIn) return [];
    final sessionId = await loadSessionId();
    final hasSessionId = sessionId != null && sessionId.isNotEmpty;
    if (!hasSessionId) return [];
    return loadMessagesForSession(sessionId);
  }

  /// Save the current active session ID.
  Future<void> saveSessionId(String sessionId) async {
    if (!_isLoggedIn) return;
    final sessionBox = await _openSessionBox();
    await sessionBox.put(_K_SESSION_ID_KEY, sessionId);
  }

  /// Clear the current active session ID while leaving session history intact.
  Future<void> clearSessionId() async {
    if (!_isLoggedIn) return;
    final sessionBox = await _openSessionBox();
    await sessionBox.delete(_K_SESSION_ID_KEY);
  }

  /// Load the current active session ID.
  Future<String?> loadSessionId() async {
    if (!_isLoggedIn) return null;
    try {
      final sessionBox = await _openSessionBox();
      return sessionBox.get(_K_SESSION_ID_KEY);
    } catch (_) {
      return null;
    }
  }

  /// Clear all chat data for the current user (on logout).
  Future<void> clearUserChatData() async {
    if (!_isLoggedIn) return;

    try {
      final messageBox = await _openHistoryBox();
      await messageBox.deleteFromDisk();

      final sessionBox = await _openSessionBox();
      await sessionBox.deleteFromDisk();
    } catch (_) {}
  }
}
