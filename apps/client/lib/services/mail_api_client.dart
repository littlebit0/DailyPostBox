import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const undoSendDelayOptions = [0, 5, 10, 20, 30];

/// Seconds the server holds a sent mail so it can still be cancelled.
final undoSendDelayProvider = StateProvider<int>((ref) => 5);

class SendReceipt {
  const SendReceipt(this.id, this.remaining);
  final String id;
  final Duration remaining;
}

class ComposeDraft {
  const ComposeDraft({
    required this.accountId,
    required this.to,
    required this.subject,
    required this.body,
    this.cc = '',
    this.inReplyTo,
    this.references = const [],
  });
  final String accountId;
  final String to;
  final String cc;
  final String subject;
  final String body;
  final String? inReplyTo;
  final List<String> references;
}

class SendOutcome {
  const SendOutcome({required this.status, this.error, this.draft});
  final String status;
  final String? error;
  final ComposeDraft? draft;
}

final mailApiClientProvider = Provider<MailApiClient>((ref) {
  return MailApiClient(baseUrl: resolveMailApiBaseUrl());
});

String resolveMailApiBaseUrl({
  String configured = const String.fromEnvironment('MAIL_API_BASE_URL'),
  bool isRelease = kReleaseMode,
}) {
  if (configured.trim().isNotEmpty) return configured.trim();
  return isRelease ? 'https://api.dailypostbox.com' : 'http://127.0.0.1:4000';
}

bool isMailApiConnectionError(Object error) {
  if (error is! DioException) return false;
  return switch (error.type) {
    DioExceptionType.connectionError ||
    DioExceptionType.connectionTimeout ||
    DioExceptionType.sendTimeout ||
    DioExceptionType.receiveTimeout ||
    DioExceptionType.badCertificate => true,
    DioExceptionType.unknown => error.response == null,
    _ => false,
  };
}

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

  Future<List<MailSummary>> fetchAccountMessages(String accountId) async {
    final response = await _dio.get<List<dynamic>>(
      '/accounts/$accountId/messages',
    );
    final data = response.data ?? [];
    return data
        .map((item) => MailSummary.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<List<MailSummary>> fetchThread(
    String accountId,
    String threadId,
  ) async {
    final response = await _dio.get<List<dynamic>>(
      '/accounts/$accountId/threads/${Uri.encodeComponent(threadId)}',
    );
    final data = response.data ?? [];
    return data
        .map((item) => MailSummary.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<List<MailSummary>> searchAccountMessages(
    String accountId,
    String query,
  ) async {
    final response = await _dio.get<List<dynamic>>(
      '/accounts/$accountId/search',
      queryParameters: {'q': query},
      options: Options(receiveTimeout: const Duration(seconds: 60)),
    );
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
          (item) => MailAccountSummary.fromJson(item as Map<String, dynamic>),
        )
        .toList();
  }

  Future<List<MailProviderSummary>> fetchProviders() async {
    final response = await _dio.get<List<dynamic>>('/providers');
    final data = response.data ?? [];
    return data
        .map(
          (item) => MailProviderSummary.fromJson(item as Map<String, dynamic>),
        )
        .toList();
  }

  Future<MessageDetail> fetchAccountMessage({
    required String accountId,
    required String messageId,
    bool remoteImages = false,
  }) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/accounts/$accountId/messages/$messageId',
      queryParameters: remoteImages ? {'remoteImages': 'allow'} : null,
    );
    return MessageDetail.fromJson(response.data ?? {});
  }

  Future<bool> fetchAiSummaryEnabled() async {
    final response = await _dio.get<Map<String, dynamic>>('/features');
    return response.data?['aiSummary'] == true;
  }

  Future<String> summarizeMessage({
    required String accountId,
    required String messageId,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/accounts/$accountId/messages/$messageId/summary',
      options: Options(receiveTimeout: const Duration(seconds: 60)),
    );
    return response.data?['summary'] as String? ?? '';
  }

  Future<void> setMessageFlags({
    required String accountId,
    required String messageId,
    bool? seen,
    bool? flagged,
  }) async {
    await _dio.post(
      '/accounts/$accountId/messages/${Uri.encodeComponent(messageId)}/flags',
      data: {
        if (seen != null) 'seen': seen,
        if (flagged != null) 'flagged': flagged,
      },
    );
  }

  Future<void> downloadAttachment({
    required String accountId,
    required String messageId,
    required String part,
    required String savePath,
  }) async {
    // Download into a unique app-accessible temp dir (the sandbox may deny
    // writes next to the selected file); touch the destination only on success.
    final tempDir = await Directory.systemTemp.createTemp('attachment_');
    try {
      final temp = File('${tempDir.path}/download');
      await _dio.download(
        '/accounts/$accountId/messages/$messageId/attachments/$part',
        temp.path,
        options: Options(receiveTimeout: const Duration(minutes: 2)),
      );
      await temp.copy(savePath);
    } finally {
      await tempDir.delete(recursive: true);
    }
  }

  Future<void> addAccount({
    required String providerId,
    required String emailAddress,
    required String authMode,
    required String incomingProtocol,
    required String secret,
    required InitialSyncOption initialSync,
    ConnectionOverride? connectionOverride,
  }) async {
    await _dio.post(
      '/accounts',
      data: {
        'providerId': providerId,
        'emailAddress': emailAddress,
        'authMode': authMode,
        'incomingProtocol': incomingProtocol,
        'secret': secret,
        'initialSync': initialSync.toJson(),
        if (connectionOverride != null)
          'connectionOverride': connectionOverride.toJson(),
      },
    );
  }

  Future<void> validateAccount({
    required String providerId,
    required String emailAddress,
    required String authMode,
    required String incomingProtocol,
    required String secret,
    required InitialSyncOption initialSync,
    ConnectionOverride? connectionOverride,
  }) async {
    await _dio.post(
      '/accounts/validate',
      data: {
        'providerId': providerId,
        'emailAddress': emailAddress,
        'authMode': authMode,
        'incomingProtocol': incomingProtocol,
        'secret': secret,
        'initialSync': initialSync.toJson(),
        if (connectionOverride != null)
          'connectionOverride': connectionOverride.toJson(),
      },
    );
  }

  Future<OAuthStartResult> startOAuthLogin({
    required String providerId,
    String? reconnectAccountId,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/auth/$providerId/start',
      data: {if (reconnectAccountId != null) 'accountId': reconnectAccountId},
    );
    return OAuthStartResult.fromJson(response.data ?? {});
  }

  Future<OAuthSessionStatus> fetchOAuthSession(String state) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/auth/sessions/$state',
    );
    return OAuthSessionStatus.fromJson(response.data ?? {});
  }

  Future<void> completeOAuthLogin({
    required String state,
    required String incomingProtocol,
    required InitialSyncOption initialSync,
  }) async {
    await _dio.post(
      '/auth/sessions/$state/complete',
      data: {
        'incomingProtocol': incomingProtocol,
        'initialSync': initialSync.toJson(),
      },
    );
  }

  Future<void> updateAccountCredentials({
    required String accountId,
    required String secret,
  }) async {
    await _dio.put(
      '/accounts/$accountId/credentials',
      data: {'secret': secret},
    );
  }

  Future<void> updateAccountSignature({
    required String accountId,
    required String signature,
  }) async {
    await _dio.put(
      '/accounts/$accountId/signature',
      data: {'signature': signature},
    );
  }

  Future<void> validateStoredAccount(String accountId) async {
    await _dio.post('/accounts/$accountId/validate');
  }

  Future<void> syncAccount(String accountId) async {
    await _dio.post('/accounts/$accountId/sync');
  }

  Future<void> setAccountNotifications(String accountId, bool enabled) async {
    await _dio.patch(
      '/accounts/$accountId/notifications',
      data: {'enabled': enabled},
    );
  }

  /// Returns the OAuth revoke outcome: revoked, skipped, unsupported or failed.
  Future<String> deleteAccount(String accountId) async {
    final response = await _dio.delete('/accounts/$accountId');
    final data = response.data;
    return data is Map ? '${data['revoke'] ?? 'skipped'}' : 'skipped';
  }

  Future<void> snoozeMessage({
    required String accountId,
    required String messageId,
    required DateTime wakeAt,
  }) async {
    await _dio.post(
      '/accounts/$accountId/messages/${Uri.encodeComponent(messageId)}/snooze',
      data: {'wakeAt': wakeAt.toUtc().toIso8601String()},
    );
  }

  Future<void> registerPushToken({
    required String platform,
    required String token,
  }) async {
    await _dio.post(
      '/devices/push-token',
      data: {'platform': platform, 'token': token},
    );
  }

  Future<List<String>> suggestContacts(String query) async {
    final response = await _dio.get<List<dynamic>>(
      '/contacts/suggest',
      queryParameters: {'q': query},
    );
    return (response.data ?? [])
        .map((item) => (item as Map<String, dynamic>)['address'] as String)
        .toList();
  }

  Future<void> unsubscribeByMail({
    required String accountId,
    required String messageId,
  }) async {
    await _dio.post('/accounts/$accountId/messages/$messageId/unsubscribe');
  }

  /// Queues the mail on the server; the receipt carries the id and the server's send deadline.
  Future<SendReceipt> sendMail({
    required String accountId,
    required List<String> to,
    required String subject,
    required String body,
    int delaySeconds = 5,
    List<String> cc = const [],
    String? inReplyTo,
    List<String> references = const [],
  }) async {
    final elapsed = Stopwatch()..start();
    final response = await _dio.post(
      '/mail/send',
      data: {
        'accountId': accountId,
        'to': to,
        if (cc.isNotEmpty) 'cc': cc,
        'subject': subject,
        'text': body,
        'delaySeconds': delaySeconds,
        if (inReplyTo != null) 'inReplyTo': inReplyTo,
        if (inReplyTo != null && references.isNotEmpty)
          'references': references,
      },
    );
    final data = response.data as Map<String, dynamic>;
    // remaining = sendAt - server now, so client clock skew does not matter. The whole
    // round trip is subtracted too: response transit is unknown, so err on the short side.
    final remaining =
        DateTime.parse(
          data['sendAt'] as String,
        ).difference(DateTime.parse(data['now'] as String)) -
        elapsed.elapsed;
    return SendReceipt(data['id'] as String, remaining);
  }

  /// Returns the resulting status: 'cancelled', or why it could not be cancelled.
  Future<String> cancelSend(String id) async {
    final response = await _dio.post(
      '/mail/send/$id/cancel',
      options: Options(validateStatus: (code) => code == 200 || code == 409),
    );
    return (response.data as Map<String, dynamic>)['status'] as String;
  }

  Future<SendOutcome> fetchSendOutcome(String id) async {
    final response = await _dio.get('/mail/send/$id');
    final data = response.data as Map<String, dynamic>;
    final draft = data['draft'] as Map<String, dynamic>?;
    return SendOutcome(
      status: data['status'] as String,
      error: data['error'] as String?,
      draft: draft == null
          ? null
          : ComposeDraft(
              accountId: draft['accountId'] as String,
              to: (draft['to'] as List).cast<String>().join(', '),
              cc: ((draft['cc'] as List?) ?? const []).cast<String>().join(
                ', ',
              ),
              subject: draft['subject'] as String? ?? '',
              body: draft['text'] as String? ?? '',
              inReplyTo: draft['inReplyTo'] as String?,
              references: ((draft['references'] as List?) ?? const [])
                  .cast<String>(),
            ),
    );
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
    this.category,
    this.threadId,
    this.threadCount = 1,
    this.flagged = false,
  });

  /// Null until the server has classified the message.
  final String? category;
  final String id;
  final String sender;
  final String subject;
  final String snippet;
  final String receivedAtLabel;
  final bool unread;
  final String? threadId;
  final int threadCount;
  final bool flagged;

  factory MailSummary.fromJson(Map<String, dynamic> json) {
    return MailSummary(
      id: json['id'] as String,
      sender: json['from'] as String? ?? '',
      subject: json['subject'] as String? ?? '',
      snippet: json['snippet'] as String? ?? '',
      receivedAtLabel: _formatReceivedAt(json['receivedAt'] as String?),
      category: json['category'] as String?,
      threadId: json['threadId'] as String?,
      threadCount: json['threadCount'] as int? ?? 1,
      unread: !(json['seen'] as bool? ?? false),
      flagged: json['flagged'] as bool? ?? false,
    );
  }
}

/// Unclassified mail (null category) shows only under "All".
List<MailSummary> filterByCategory(List<MailSummary> items, String? category) =>
    category == null
    ? items
    : items.where((m) => m.category == category).toList();

/// Keeps the first (newest) message of each thread. Mail without a thread id
/// stays as its own row.
List<MailSummary> groupByThread(List<MailSummary> items) {
  final seen = <String>{};
  return [
    for (final item in items)
      if (item.threadId == null || seen.add(item.threadId!)) item,
  ];
}

class MessageDetail {
  const MessageDetail({
    required this.id,
    required this.sender,
    required this.subject,
    required this.body,
    required this.links,
    required this.receivedAtLabel,
    this.signed = false,
    this.encrypted = false,
    this.invite,
    this.authenticationFailures = const [],
    this.unsubscribeUrl,
    this.unsubscribeMailto,
    this.html = '',
    this.remoteImageCount = 0,
    this.seen = false,
    this.flagged = false,
    this.attachments = const [],
    this.receivedAt,
    this.accountId,
    this.messageId,
    this.references = const [],
    this.replyTo = const [],
    this.replyAllTo = const [],
    this.replyAllCc = const [],
  });

  final bool seen;
  final bool flagged;
  final String? accountId;
  final String? messageId;
  final List<String> references;
  final List<String> replyTo;
  final List<String> replyAllTo;
  final List<String> replyAllCc;
  final CalendarInvite? invite;
  final String id;
  final String sender;
  final String subject;
  final String body;
  final String html;
  final int remoteImageCount;
  final List<MessageLink> links;
  final List<String> authenticationFailures;
  final String receivedAtLabel;
  final bool signed;
  final bool encrypted;
  final String? unsubscribeUrl;
  final String? unsubscribeMailto;

  bool get canUnsubscribe =>
      unsubscribeUrl != null ||
      (unsubscribeMailto != null && accountId != null);
  final List<MessageAttachment> attachments;
  final DateTime? receivedAt;

  factory MessageDetail.fromJson(Map<String, dynamic> json) {
    final unsubscribe = json['unsubscribe'] as Map<String, dynamic>?;
    final mailto = unsubscribe?['mailto'] as Map<String, dynamic>?;
    return MessageDetail(
      unsubscribeUrl: unsubscribe?['url'] as String?,
      unsubscribeMailto: mailto?['address'] as String?,
      id: json['id'] as String? ?? '',
      sender: json['from'] as String? ?? '',
      subject: json['subject'] as String? ?? '',
      body: json['body'] as String? ?? '',
      html: json['html'] as String? ?? '',
      remoteImageCount: json['remoteImageCount'] as int? ?? 0,
      links: (json['bodyLinks'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(MessageLink.fromJson)
          .toList(growable: false),
      receivedAtLabel: _formatReceivedAt(json['receivedAt'] as String?),
      signed: (json['security'] as Map?)?['signed'] != null,
      encrypted: (json['security'] as Map?)?['encrypted'] != null,
      invite: json['invite'] is Map<String, dynamic>
          ? CalendarInvite.fromJson(json['invite'] as Map<String, dynamic>)
          : null,
      authenticationFailures:
          (json['authenticationFailures'] as List<dynamic>? ?? const [])
              .whereType<String>()
              .toList(growable: false),
      seen: json['seen'] as bool? ?? false,
      flagged: json['flagged'] as bool? ?? false,
      attachments: (json['attachments'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(MessageAttachment.fromJson)
          .toList(growable: false),
      receivedAt: DateTime.tryParse(
        json['receivedAt'] as String? ?? '',
      )?.toLocal(),
      accountId: json['accountId'] as String?,
      messageId: json['messageId'] as String?,
      references: _strings(json['references']),
      replyTo: _strings(json['replyTo']),
      replyAllTo: _strings(json['replyAllTo']),
      replyAllCc: _strings(json['replyAllCc']),
    );
  }
}

class CalendarInvite {
  const CalendarInvite({
    required this.summary,
    required this.start,
    this.end,
    this.allDay = false,
    this.location,
    this.organizer,
    this.recurring = false,
    this.method,
  });

  final String summary;

  /// ISO 8601 from the server: UTC with "Z", a date for all-day events, or a
  /// wall-clock time without offset when the sender's zone was unknown.
  final String start;
  final String? end;
  final bool allDay;
  final String? location;
  final String? organizer;
  final bool recurring;

  /// iTIP METHOD (REQUEST, CANCEL, ...), upper-cased by the server.
  final String? method;

  bool get cancelled => method == 'CANCEL';

  factory CalendarInvite.fromJson(Map<String, dynamic> json) {
    return CalendarInvite(
      summary: json['summary'] as String? ?? '',
      start: json['start'] as String? ?? '',
      end: json['end'] as String?,
      allDay: json['allDay'] as bool? ?? false,
      location: json['location'] as String?,
      organizer: json['organizer'] as String?,
      recurring: json['recurring'] as bool? ?? false,
      method: json['method'] as String?,
    );
  }

  /// "2026-12-01 09:00 ~ 10:00", shown in the device time zone when the
  /// server could resolve the sender's zone.
  String get timeLabel {
    final from = _inviteTime(start, allDay);
    final to = end == null ? null : _inviteTime(_inclusiveEnd(end!), allDay);
    if (to == null || to == from) return from;
    final sameDay = !allDay && from.substring(0, 10) == to.substring(0, 10);
    return '$from ~ ${sameDay ? to.substring(11) : to}';
  }

  /// All-day DTEND is exclusive (RFC 5545 §3.6.1), so show the day before it.
  String _inclusiveEnd(String value) {
    final date = allDay ? DateTime.tryParse(value) : null;
    if (date == null) return value;
    return DateTime(date.year, date.month, date.day - 1).toIso8601String();
  }
}

String _inviteTime(String value, bool allDay) {
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return value;
  final local = parsed.isUtc ? parsed.toLocal() : parsed;
  String two(int n) => n.toString().padLeft(2, '0');
  final date = '${local.year}-${two(local.month)}-${two(local.day)}';
  return allDay ? date : '$date ${two(local.hour)}:${two(local.minute)}';
}

class MessageAttachment {
  const MessageAttachment({
    required this.part,
    required this.filename,
    required this.contentType,
    required this.size,
  });

  final String part;
  final String filename;
  final String contentType;
  final int size;

  factory MessageAttachment.fromJson(Map<String, dynamic> json) {
    return MessageAttachment(
      part: json['part'] as String? ?? '',
      filename: json['filename'] as String? ?? '',
      contentType: json['contentType'] as String? ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
    );
  }
}

String formatAttachmentSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return '${value.toStringAsFixed(value < 10 ? 1 : 0)} ${units[unit]}';
}

List<String> _strings(Object? value) =>
    (value as List<dynamic>? ?? const []).whereType<String>().toList();

class MessageLink {
  const MessageLink({required this.url, required this.label});

  final String url;
  final String label;

  factory MessageLink.fromJson(Map<String, dynamic> json) {
    return MessageLink(
      url: json['url'] as String? ?? '',
      label: json['label'] as String? ?? '',
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
    this.syncErrorCode,
    required this.initialSync,
    required this.lastSyncedAtLabel,
    this.signature = '',
    this.threadBackfilling = false,
    this.idleSupported,
    this.capabilitiesCheckedAtLabel = '',
    this.notificationsEnabled = true,
  });

  final String id;
  final String providerId;
  final String emailAddress;
  final String signature;
  final String incomingProtocol;
  final String authMode;
  final String syncStatus;
  final String? syncError;
  final String? syncErrorCode;
  final InitialSyncOption? initialSync;
  final String lastSyncedAtLabel;
  // Server is still filling thread metadata for older messages.
  final bool threadBackfilling;
  final bool notificationsEnabled;

  /// Null until the server has logged in and read the IMAP capabilities.
  final bool? idleSupported;
  final String capabilitiesCheckedAtLabel;

  factory MailAccountSummary.fromJson(Map<String, dynamic> json) {
    final capabilities = json['incomingCapabilities'] is Map<String, dynamic>
        ? json['incomingCapabilities'] as Map<String, dynamic>
        : null;
    return MailAccountSummary(
      id: json['id'] as String,
      providerId: json['providerId'] as String,
      emailAddress: json['emailAddress'] as String,
      incomingProtocol: json['incomingProtocol'] as String,
      authMode: json['authMode'] as String? ?? '',
      syncStatus: json['syncStatus'] as String? ?? 'idle',
      syncError: json['syncError'] as String?,
      syncErrorCode: json['syncErrorCode'] as String?,
      initialSync: json['initialSync'] is Map<String, dynamic>
          ? InitialSyncOption.fromJson(
              json['initialSync'] as Map<String, dynamic>,
            )
          : null,
      lastSyncedAtLabel: _formatReceivedAt(json['lastSyncedAt'] as String?),
      signature: json['signature'] as String? ?? '',
      threadBackfilling: json['threadBackfill'] == 'running',
      idleSupported: capabilities?['idle'] as bool?,
      capabilitiesCheckedAtLabel: _formatReceivedAt(
        capabilities?['checkedAt'] as String?,
      ),
      notificationsEnabled: json['notificationsEnabled'] as bool? ?? true,
    );
  }
}

/// Incoming (IMAP) and outgoing (SMTP) servers of a custom mail account.
class ConnectionOverride {
  const ConnectionOverride({required this.incoming, required this.outgoing});

  final ServerEndpoint incoming;
  final ServerEndpoint outgoing;

  Map<String, Object> toJson() => {
    'incoming': incoming.toJson(),
    'outgoing': outgoing.toJson(),
  };
}

class ServerEndpoint {
  const ServerEndpoint({
    required this.host,
    required this.port,
    required this.secure,
  });

  final String host;
  final int port;
  final bool secure;

  Map<String, Object> toJson() => {
    'host': host,
    'port': port,
    'secure': secure,
  };
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
    return {'includePreviousMessages': includePreviousMessages, 'limit': limit};
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
