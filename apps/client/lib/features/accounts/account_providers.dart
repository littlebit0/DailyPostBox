import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/mail_api_client.dart';

final accountsProvider = FutureProvider<List<MailAccountSummary>>((ref) {
  return ref.watch(mailApiClientProvider).fetchAccounts();
});

final accountMessagesProvider =
    FutureProvider.family<List<MailSummary>, String>((ref, accountId) {
  return ref.watch(mailApiClientProvider).fetchAccountMessages(accountId);
});

final threadMessagesProvider = FutureProvider.autoDispose
    .family<List<MailSummary>, ({String accountId, String threadId})>(
        (ref, key) {
  return ref
      .watch(mailApiClientProvider)
      .fetchThread(key.accountId, key.threadId);
});

class ThreadViewController extends Notifier<bool> {
  @override
  bool build() => true;

  void set(bool value) => state = value;
}

final threadViewProvider =
    NotifierProvider<ThreadViewController, bool>(ThreadViewController.new);
