import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/language_controller.dart';
import '../../services/mail_api_client.dart';

class FailedSend {
  const FailedSend({required this.id, required this.draft, required this.error});
  final String id;
  final ComposeDraft draft;
  final String error;
}

/// App-level so a failed draft outlives the page and snackbars that reported it.
class FailedSendsNotifier extends Notifier<List<FailedSend>> {
  @override
  List<FailedSend> build() => const [];

  void add(FailedSend item) =>
      state = [...state.where((e) => e.id != item.id), item];

  void remove(String id) => state = [...state.where((e) => e.id != id)];
}

final failedSendsProvider =
    NotifierProvider<FailedSendsNotifier, List<FailedSend>>(FailedSendsNotifier.new);

/// Reopens a failed draft in the stacked recovery composer and drops it from the list.
void rewriteFailedSend(GoRouter router, FailedSendsNotifier notifier, FailedSend item) {
  notifier.remove(item.id);
  router.push('/compose/recover', extra: item.draft);
}

/// Persistent "N failed" indicator; stays until the user rewrites or deletes each draft.
class FailedSendsBanner extends ConsumerWidget {
  const FailedSendsBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(failedSendsProvider);
    if (items.isEmpty) return const SizedBox.shrink();
    final strings = ref.watch(appStringsProvider);
    final notifier = ref.read(failedSendsProvider.notifier);
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              strings.failedSendsCount(items.length),
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: scheme.onErrorContainer,
                    fontWeight: FontWeight.w700,
                  ),
            ),
            for (final item in items)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      item.draft.subject.isEmpty
                          ? item.draft.to
                          : '${item.draft.subject} · ${item.draft.to}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: scheme.onErrorContainer),
                    ),
                  ),
                  TextButton(
                    onPressed: () =>
                        rewriteFailedSend(GoRouter.of(context), notifier, item),
                    child: Text(strings.rewriteMail),
                  ),
                  TextButton(
                    onPressed: () => notifier.remove(item.id),
                    child: Text(strings.deleteFailedSend),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
