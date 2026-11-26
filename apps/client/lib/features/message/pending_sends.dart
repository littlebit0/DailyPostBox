import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/language_controller.dart';
import '../../services/mail_api_client.dart';

class PendingSend {
  const PendingSend({required this.id, required this.to, required this.subject});
  final String id;
  final String to;
  final String subject;
}

/// App-level list of sends still inside the undo window, so a newer send's snackbar
/// never takes away the way to cancel an earlier one.
class PendingSendsNotifier extends Notifier<List<PendingSend>> {
  final _timers = <String, Timer>{};

  @override
  List<PendingSend> build() {
    ref.onDispose(() {
      for (final t in _timers.values) {
        t.cancel();
      }
    });
    return const [];
  }

  /// Drops the item by itself once the server deadline passes.
  void add(PendingSend item, Duration remaining) {
    _timers[item.id]?.cancel();
    _timers[item.id] = Timer(remaining, () => remove(item.id));
    state = [...state.where((e) => e.id != item.id), item];
  }

  void remove(String id) {
    _timers.remove(id)?.cancel();
    state = [...state.where((e) => e.id != id)];
  }
}

final pendingSendsProvider =
    NotifierProvider<PendingSendsNotifier, List<PendingSend>>(
        PendingSendsNotifier.new);

/// Cancels on the server, drops the item, and reports the result in a snackbar.
Future<void> cancelPendingSend(
  MailApiClient client,
  AppStrings strings,
  ScaffoldMessengerState messenger,
  PendingSendsNotifier pending,
  String id,
) async {
  String result;
  try {
    final status = await client.cancelSend(id);
    result = switch (status) {
      'cancelled' => strings.sendCancelled,
      'failed' => strings.sendFailedShort,
      _ => strings.sendAlreadySent,
    };
    pending.remove(id);
  } catch (_) {
    result = strings.sendCancelFailed;
  }
  messenger.showSnackBar(SnackBar(content: Text(result)));
}

/// Single-row "N waiting" indicator; each send can be cancelled from its dialog.
class PendingSendsBanner extends ConsumerWidget {
  const PendingSendsBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(pendingSendsProvider);
    if (items.isEmpty) return const SizedBox.shrink();
    final strings = ref.watch(appStringsProvider);
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                strings.pendingSendsCount(items.length),
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: scheme.onSecondaryContainer,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
            TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => _PendingSendsDialog(
                    messenger: ScaffoldMessenger.of(context)),
              ),
              child: Text(strings.viewPendingSends),
            ),
          ],
        ),
      ),
    );
  }
}

class _PendingSendsDialog extends ConsumerWidget {
  const _PendingSendsDialog({required this.messenger});
  final ScaffoldMessengerState messenger;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(pendingSendsProvider);
    final strings = ref.watch(appStringsProvider);
    final notifier = ref.read(pendingSendsProvider.notifier);
    final client = ref.read(mailApiClientProvider);
    return AlertDialog(
      title: Text(strings.pendingSendsCount(items.length)),
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
                    item.subject.isEmpty
                        ? item.to
                        : '${item.subject} · ${item.to}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: () {
                    if (items.length == 1) Navigator.of(context).pop();
                    cancelPendingSend(
                        client, strings, messenger, notifier, item.id);
                  },
                  child: Text(strings.undoSend),
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
