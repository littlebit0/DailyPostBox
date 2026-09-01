import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/mail_api_client.dart';

final accountsProvider = FutureProvider<List<MailAccountSummary>>((ref) {
  return ref.watch(mailApiClientProvider).fetchAccounts();
});

final accountMessagesProvider =
    FutureProvider.family<List<MailSummary>, String>((ref, accountId) {
  return ref.watch(mailApiClientProvider).fetchAccountMessages(accountId);
});
