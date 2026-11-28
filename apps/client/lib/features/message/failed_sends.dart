import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/language_controller.dart';
import '../../services/mail_api_client.dart';

class FailedSend {
  const FailedSend(
      {required this.id, required this.draft, required this.error});
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
    NotifierProvider<FailedSendsNotifier, List<FailedSend>>(
        FailedSendsNotifier.new);

/// Reopens a failed draft in the stacked recovery composer and drops it from the list.
void rewriteFailedSend(
    GoRouter router, FailedSendsNotifier notifier, FailedSend item) {
  notifier.remove(item.id);
  router.push('/compose/recover', extra: item.draft);
}

/// Persistent single-row "N failed" indicator; the list lives in a bounded dialog so the
/// banner never grows and pushes the mail area off screen.
class FailedSendsBanner extends ConsumerWidget {
  const FailedSendsBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(failedSendsProvider);
    if (items.isEmpty) return const SizedBox.shrink();
    final strings = ref.watch(appStringsProvider);
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                strings.failedSendsCount(items.length),
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: scheme.onErrorContainer,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
            TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) =>
                    _FailedSendsDialog(router: GoRouter.of(context)),
              ),
              child: Text(strings.viewFailedSends),
            ),
          ],
        ),
      ),
    );
  }
}

class _FailedSendsDialog extends ConsumerWidget {
  const _FailedSendsDialog({required this.router});
  final GoRouter router;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(failedSendsProvider);
    final strings = ref.watch(appStringsProvider);
    final notifier = ref.read(failedSendsProvider.notifier);
    return AlertDialog(
      title: Text(strings.failedSendsCount(items.length)),
      content: SizedBox(
        width: 480,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: items.length,
          itemBuilder: (context, i) {
            final item = items[i];
            return Row(
              children: [
                Expanded(
                  child: Text(
                    item.draft.subject.isEmpty
                        ? item.draft.to
                        : '${item.draft.subject} · ${item.draft.to}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                    rewriteFailedSend(router, notifier, item);
                  },
                  child: Text(strings.rewriteMail),
                ),
                TextButton(
                  onPressed: () {
                    if (items.length == 1) Navigator.of(context).pop();
                    notifier.remove(item.id);
                  },
                  child: Text(strings.deleteFailedSend),
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.close),
        ),
      ],
    );
  }
}
