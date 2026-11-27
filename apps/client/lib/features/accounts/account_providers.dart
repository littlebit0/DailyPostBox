import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/mail_api_client.dart';

final accountsProvider = FutureProvider<List<MailAccountSummary>>((ref) {
  return ref.watch(mailApiClientProvider).fetchAccounts();
});

final accountMessagesProvider =
    FutureProvider.family<List<MailSummary>, String>((ref, accountId) {
  // A list fetched mid-sync is partial, so fetch it again once the account's
  // sync finishes, whichever screen (or the Dock badge) loaded it.
  ref.listen<AsyncValue<List<MailAccountSummary>>>(accountsProvider, (
    previous,
    next,
  ) {
    // Thread backfill also rewrites the list (thread ids), so treat it as busy.
    bool busy(AsyncValue<List<MailAccountSummary>>? value) {
      final account = value?.valueOrNull
          ?.where((account) => account.id == accountId)
          .firstOrNull;
      return account != null &&
          (account.threadBackfilling ||
              _syncingStatuses.contains(account.syncStatus));
    }

    if (busy(previous) && !busy(next)) {
      ref.invalidateSelf();
    }
  });
  return ref.watch(mailApiClientProvider).fetchAccountMessages(accountId);
});

const _syncingStatuses = {'syncing', 'validating'};

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
