import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final mailApiClientProvider = Provider<MailApiClient>((ref) {
  return MailApiClient(
    baseUrl: const String.fromEnvironment(
      'MAIL_API_BASE_URL',
      defaultValue: 'https://api.dailypostbox.com',
    ),
  );
});

class MailApiClient {
  MailApiClient({required String baseUrl})
      : _dio = Dio(
          BaseOptions(
            baseUrl: baseUrl,
            connectTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 30),
          ),
        );

  final Dio _dio;

  Future<List<MailSummary>> fetchInbox() async {
    final response = await _dio.get<List<dynamic>>('/mail/inbox');
    final data = response.data ?? [];
    return data
        .map((item) => MailSummary.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<List<MailSummary>> fetchAccountMessages(String accountId) async {
    final response =
        await _dio.get<List<dynamic>>('/accounts/$accountId/messages');
    final data = response.data ?? [];
    return data
        .map((item) => MailSummary.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<List<MailAccountSummary>> fetchAccounts() async {
    final response = await _dio.get<List<dynamic>>('/accounts');
    final data = response.data ?? [];
    return data
        .map(
            (item) => MailAccountSummary.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<List<MailProviderSummary>> fetchProviders() async {
    final response = await _dio.get<List<dynamic>>('/providers');
    final data = response.data ?? [];
    return data
        .map((item) =>
            MailProviderSummary.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<MessageDetail> fetchMessage(String messageId) async {
    final response =
        await _dio.get<Map<String, dynamic>>('/mail/messages/$messageId');
    return MessageDetail.fromJson(response.data ?? {});
  }

  Future<void> addAccount({
    required String providerId,
    required String emailAddress,
    required String authMode,
    required String incomingProtocol,
    required String secret,
    required InitialSyncOption initialSync,
  }) async {
    await _dio.post('/accounts', data: {
      'providerId': providerId,
      'emailAddress': emailAddress,
      'authMode': authMode,
      'incomingProtocol': incomingProtocol,
      'secret': secret,
      'initialSync': initialSync.toJson(),
    });
  }

  Future<void> validateAccount({
    required String providerId,
    required String emailAddress,
    required String authMode,
    required String incomingProtocol,
    required String secret,
    required InitialSyncOption initialSync,
  }) async {
    await _dio.post('/accounts/validate', data: {
      'providerId': providerId,
      'emailAddress': emailAddress,
      'authMode': authMode,
      'incomingProtocol': incomingProtocol,
      'secret': secret,
      'initialSync': initialSync.toJson(),
    });
  }

  Future<OAuthStartResult> startOAuthLogin({
    required String providerId,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/auth/$providerId/start',
      data: const {},
    );
    return OAuthStartResult.fromJson(response.data ?? {});
  }

  Future<OAuthSessionStatus> fetchOAuthSession(String state) async {
    final response =
        await _dio.get<Map<String, dynamic>>('/auth/sessions/$state');
    return OAuthSessionStatus.fromJson(response.data ?? {});
  }

  Future<void> completeOAuthLogin({
    required String state,
    required String incomingProtocol,
    required InitialSyncOption initialSync,
  }) async {
    await _dio.post('/auth/sessions/$state/complete', data: {
      'incomingProtocol': incomingProtocol,
      'initialSync': initialSync.toJson(),
    });
  }

  Future<void> validateStoredAccount(String accountId) async {
    await _dio.post('/accounts/$accountId/validate');
  }

  Future<void> syncAccount(String accountId) async {
    await _dio.post('/accounts/$accountId/sync');
  }

  Future<void> deleteAccount(String accountId) async {
    await _dio.delete('/accounts/$accountId');
  }

  Future<void> registerPushToken({
    required String platform,
    required String token,
  }) async {
    await _dio.post('/devices/push-token', data: {
      'platform': platform,
      'token': token,
    });
  }

  Future<void> sendMail({
    required String accountId,
    required List<String> to,
    required String subject,
    required String body,
  }) async {
    await _dio.post('/mail/send', data: {
      'accountId': accountId,
      'to': to,
      'subject': subject,
      'text': body,
    });
  }
}

class OAuthStartResult {
  const OAuthStartResult({
    required this.state,
    required this.authorizationUrl,
    required this.expiresAt,
  });

  final String state;
  final String authorizationUrl;
  final String expiresAt;

  factory OAuthStartResult.fromJson(Map<String, dynamic> json) {
    return OAuthStartResult(
      state: json['state'] as String? ?? '',
      authorizationUrl: json['authorizationUrl'] as String? ?? '',
      expiresAt: json['expiresAt'] as String? ?? '',
    );
  }
}

class OAuthSessionStatus {
  const OAuthSessionStatus({
    required this.state,
    required this.status,
    this.error,
    this.accountId,
    this.emailAddress,
  });

  final String state;
  final String status;
  final String? error;
  final String? accountId;
  final String? emailAddress;

  factory OAuthSessionStatus.fromJson(Map<String, dynamic> json) {
    return OAuthSessionStatus(
      state: json['state'] as String? ?? '',
      status: json['status'] as String? ?? 'waiting',
      error: json['error'] as String?,
      accountId: json['accountId'] as String?,
      emailAddress: json['emailAddress'] as String?,
    );
  }
}

class MailSummary {
  const MailSummary({
    required this.id,
    required this.sender,
    required this.subject,
    required this.snippet,
    required this.receivedAtLabel,
    required this.unread,
  });

  final String id;
  final String sender;
  final String subject;
  final String snippet;
  final String receivedAtLabel;
  final bool unread;

  factory MailSummary.fromJson(Map<String, dynamic> json) {
    return MailSummary(
      id: json['id'] as String,
      sender: json['from'] as String? ?? '',
      subject: json['subject'] as String? ?? '',
      snippet: json['snippet'] as String? ?? '',
      receivedAtLabel: _formatReceivedAt(json['receivedAt'] as String?),
      unread: true,
    );
  }
}

class MessageDetail {
  const MessageDetail({
    required this.id,
    required this.sender,
    required this.subject,
    required this.body,
    required this.receivedAtLabel,
  });

  final String id;
  final String sender;
  final String subject;
  final String body;
  final String receivedAtLabel;

  factory MessageDetail.fromJson(Map<String, dynamic> json) {
    return MessageDetail(
      id: json['id'] as String? ?? '',
      sender: json['from'] as String? ?? '',
      subject: json['subject'] as String? ?? '',
      body: json['body'] as String? ?? '',
      receivedAtLabel: _formatReceivedAt(json['receivedAt'] as String?),
    );
  }
}

class MailAccountSummary {
  const MailAccountSummary({
    required this.id,
    required this.providerId,
    required this.emailAddress,
    required this.incomingProtocol,
    required this.authMode,
    required this.syncStatus,
    required this.syncError,
    required this.initialSync,
    required this.lastSyncedAtLabel,
  });

  final String id;
  final String providerId;
  final String emailAddress;
  final String incomingProtocol;
  final String authMode;
  final String syncStatus;
  final String? syncError;
  final InitialSyncOption? initialSync;
  final String lastSyncedAtLabel;

  factory MailAccountSummary.fromJson(Map<String, dynamic> json) {
    return MailAccountSummary(
      id: json['id'] as String,
      providerId: json['providerId'] as String,
      emailAddress: json['emailAddress'] as String,
      incomingProtocol: json['incomingProtocol'] as String,
      authMode: json['authMode'] as String? ?? '',
      syncStatus: json['syncStatus'] as String? ?? 'idle',
      syncError: json['syncError'] as String?,
      initialSync: json['initialSync'] is Map<String, dynamic>
          ? InitialSyncOption.fromJson(
              json['initialSync'] as Map<String, dynamic>)
          : null,
      lastSyncedAtLabel: _formatReceivedAt(json['lastSyncedAt'] as String?),
    );
  }
}

class InitialSyncOption {
  const InitialSyncOption({
    required this.includePreviousMessages,
    required this.limit,
  });

  final bool includePreviousMessages;
  final Object limit;

  static const recommended = InitialSyncOption(
    includePreviousMessages: true,
    limit: 100,
  );

  Map<String, Object> toJson() {
    return {
      'includePreviousMessages': includePreviousMessages,
      'limit': limit,
    };
  }

  factory InitialSyncOption.fromJson(Map<String, dynamic> json) {
    return InitialSyncOption(
      includePreviousMessages: json['includePreviousMessages'] as bool? ?? true,
      limit: json['limit'] ?? 100,
    );
  }

  String labelKo() {
    if (!includePreviousMessages) return '이전 이메일 가져오지 않기';
    if (limit == 'all') return '전부 가져오기';
    return '최근 $limit개 가져오기';
  }

  String labelEn() {
    if (!includePreviousMessages) return 'Do not import previous mail';
    if (limit == 'all') return 'Import everything';
    return 'Latest $limit messages';
  }

  @override
  bool operator ==(Object other) {
    return other is InitialSyncOption &&
        other.includePreviousMessages == includePreviousMessages &&
        other.limit == limit;
  }

  @override
  int get hashCode => Object.hash(includePreviousMessages, limit);
}

class MailProviderSummary {
  const MailProviderSummary({
    required this.id,
    required this.displayName,
    required this.authModes,
    required this.defaultProtocol,
    required this.supportsOAuth,
  });

  final String id;
  final String displayName;
  final List<String> authModes;
  final String defaultProtocol;
  final bool supportsOAuth;

  factory MailProviderSummary.fromJson(Map<String, dynamic> json) {
    final incoming = json['incoming'] as Map<String, dynamic>? ?? {};
    return MailProviderSummary(
      id: json['id'] as String,
      displayName: json['displayName'] as String,
      authModes: (json['authModes'] as List<dynamic>? ?? [])
          .map((item) => item.toString())
          .toList(),
      defaultProtocol: incoming['protocol'] as String? ?? 'imap',
      supportsOAuth: json['supportsOAuth'] as bool? ?? false,
    );
  }
}

String _formatReceivedAt(String? value) {
  if (value == null) return '';
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return '';
  final now = DateTime.now();
  final difference = now.difference(parsed.toLocal());

  if (difference.inMinutes < 1) return 'now';
  if (difference.inHours < 1) return '${difference.inMinutes}m';
  if (difference.inDays < 1) return '${difference.inHours}h';
  return '${parsed.month}/${parsed.day}';
}
