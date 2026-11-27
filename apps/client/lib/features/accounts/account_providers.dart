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
    String? status(AsyncValue<List<MailAccountSummary>>? value) =>
        value?.valueOrNull
            ?.where((account) => account.id == accountId)
            .firstOrNull
            ?.syncStatus;
    if (_syncingStatuses.contains(status(previous)) &&
        !_syncingStatuses.contains(status(next))) {
      ref.invalidateSelf();
    }
  });
  return ref.watch(mailApiClientProvider).fetchAccountMessages(accountId);
});

const _syncingStatuses = {'syncing', 'validating'};
