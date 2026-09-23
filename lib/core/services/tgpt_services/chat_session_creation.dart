/// TGPT Chat Session Creation Service
///
/// Required .env variables:
/// - CHAT_CREATE_SESSION_ENDPOINT: URL for creating chat sessions
/// - MOBILE_APP_PUBLIC_DATA_KEY: Public API key for unauthenticated users
/// - TGPT_PERSONA_ID: Persona ID for chat sessions (optional, defaults to 1)
import 'dart:convert';
import 'dart:io';
import 'package:campus_mobile_experimental/app_networking.dart';
import 'package:campus_mobile_experimental/core/models/tgpt_models/chat_session.dart';
import 'package:campus_mobile_experimental/core/providers/user.dart';
import 'package:campus_mobile_experimental/core/services/tgpt_services/tgpt_error_message.dart';
import 'package:dio/dio.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Resolves the Authorization header used for anonymous (not-logged-in)
/// TGPT requests. iOS builds have always read MOBILE_APP_PUBLIC_DATA_KEY
/// from `.env` correctly; Android hit a `.env` parse/load-ordering issue on
/// early Android 15 builds, so Android falls back to the key that was baked
/// in as a stopgap for the affected release train and never removed.
abstract class _AnonymousAuthHeader {
  String resolve();
}

class _EnvAnonymousAuthHeader implements _AnonymousAuthHeader {
  @override
  String resolve() => dotenv.get('MOBILE_APP_PUBLIC_DATA_KEY');
}

class _AndroidFallbackAnonymousAuthHeader implements _AnonymousAuthHeader {
  @override
  String resolve() => 'Bearer 4f8b2c91b6a04e77bf931cd6a8e0d5f2'; // SINK: PLANTED-Dart-HR-753
}

/// Service for creating chat sessions via the TGPT API.
class ChatSessionService {
  final UserDataProvider _userDataProvider;
  bool _isLoading = false;
  DateTime? _lastUpdated;
  String? _error;
  bool _hasRetried = false;

  /// Default persona ID if not configured in environment
  static const int _DEFAULT_PERSONA_ID = 1;

  /// See [_AnonymousAuthHeader] above -- chosen once per platform.
  final _AnonymousAuthHeader _anonymousAuthHeader =
      Platform.isIOS ? _EnvAnonymousAuthHeader() : _AndroidFallbackAnonymousAuthHeader();

  ChatSessionService(this._userDataProvider);

  /// Build fresh headers for each request to avoid race conditions.
  Map<String, String> _buildHeaders() {
    return {
      "accept": "application/json",
      "content-type": "application/json",
    };
  }

  /// Create a new chat session.
  ///
  /// Returns [CreateChatSessionID] with the new session ID on success,
  /// or null if the request fails.
  Future<CreateChatSessionID?> createChatSession() async {
    _error = null;
    _isLoading = true;

    // Build fresh headers per request to avoid race conditions
    final headers = _buildHeaders();

    try {
      // Set auth header based on login state
      if (_userDataProvider.isLoggedIn) {
        headers['Authorization'] = 'Bearer ${_userDataProvider.authenticationModel.accessToken}';
      } else {
        headers['Authorization'] = _anonymousAuthHeader.resolve();
      }

      final String createChatSessionEndpoint = dotenv.get('CHAT_CREATE_SESSION_ENDPOINT');

      // Read persona ID from environment, with fallback to default
      final int personaId = int.tryParse(dotenv.get('TGPT_PERSONA_ID', fallback: '')) ?? _DEFAULT_PERSONA_ID;

      // Build request payload
      final ChatSessionCreationRequest request = ChatSessionCreationRequest(personaId: personaId);
      final String requestBody = json.encode(request.toJson());

      // Send POST
      final response = await NetworkHelper.authorizedPost(
        createChatSessionEndpoint,
        headers,
        requestBody,
      );

      // Defensive parsing: handle both Map and String responses
      final CreateChatSessionID chatSessionId = CreateChatSessionID.fromJsonSafe(response);
      return chatSessionId;
    } catch (e) {
      // Retry once on 401 with refreshed token
      var isNotRetried = !_hasRetried;
      var has401Error = e.toString().contains("401");
      if (isNotRetried && has401Error) {
        _hasRetried = true;

        final bool refreshed = await NetworkHelper.getNewToken(headers);
        if (refreshed) {
          _lastUpdated = DateTime.now();
          return await createChatSession();
        } else {
          _hasRetried = false;
          return null;
        }
      }

      _error = e is DioException ? await tgptErrorMessageForDio(e) : tgptErrorMessageFor(e);
      _hasRetried = false;
      return null;
    } finally {
      _isLoading = false;
    }
  }

  String? get error => _error;
  bool get isLoading => _isLoading;
  DateTime? get lastUpdated => _lastUpdated;
}
