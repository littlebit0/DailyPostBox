import 'package:flutter/material.dart';

final _addressPattern = RegExp(r'^[^\s@,;<>]+@[^\s@,;<>]+\.[^\s@,;<>]+$');

bool isValidEmailAddress(String value) => _addressPattern.hasMatch(value);

/// Moves typed text in [controller] into [addresses] as chips.
/// Returns whether any address was added.
bool commitRecipientText(
    List<String> addresses, TextEditingController controller) {
  final parts = controller.text
      .split(RegExp(r'[,;\s]+'))
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty);
  var changed = false;
  for (final part in parts) {
    if (!addresses.contains(part)) {
      addresses.add(part);
      changed = true;
    }
  }
  controller.clear();
  return changed;
}

bool hasInvalidRecipient(List<String> addresses) =>
    addresses.any((item) => !isValidEmailAddress(item));

/// Chip input for recipients with async address suggestions.
///
/// [addresses] and [controller] are owned by the parent so the input survives
/// this widget being disposed (e.g. scrolled out of a lazy list).
class RecipientField extends StatefulWidget {
  const RecipientField({
    super.key,
    required this.label,
    required this.errorText,
    required this.suggest,
    required this.addresses,
    required this.controller,
  });

  final String label;
  final String errorText;
  final Future<List<String>> Function(String query) suggest;
  final List<String> addresses;
  final TextEditingController controller;

  @override
  State<RecipientField> createState() => _RecipientFieldState();
}

class _RecipientFieldState extends State<RecipientField> {
  final _focusNode = FocusNode();
  int _request = 0;

  List<String> get _addresses => widget.addresses;

  void _commit() {
    if (commitRecipientText(_addresses, widget.controller)) setState(() {});
  }

  void _remove(String address) {
    setState(() => _addresses.remove(address));
  }

  Future<Iterable<String>> _options(TextEditingValue value) async {
    final query = value.text.trim();
    if (query.length < 2) return const [];
    final request = ++_request;
    try {
      final result = await widget.suggest(query);
      if (request != _request) return const [];
      final options = result.where((item) => !_addresses.contains(item));
      // A fully typed address stays first so Enter never swaps it for a lookalike.
      if (!isValidEmailAddress(query) || _addresses.contains(query)) {
        return options;
      }
      return [query, ...options.where((item) => item != query)];
    } catch (_) {
      return const [];
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RawAutocomplete<String>(
      focusNode: _focusNode,
      textEditingController: widget.controller,
      optionsBuilder: _options,
      onSelected: (address) {
        // Defer: RawAutocomplete rewrites the field text right after onSelected.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          widget.controller.text = address;
          _commit();
          _focusNode.requestFocus();
        });
      },
      fieldViewBuilder: (context, controller, focusNode, onSubmit) {
        return InputDecorator(
          decoration: InputDecoration(
            labelText: widget.label,
            errorText: hasInvalidRecipient(_addresses)
                ? widget.errorText : null,
          ),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final address in _addresses)
                InputChip(
                  label: Text(address),
                  backgroundColor: isValidEmailAddress(address)
                      ? null
                      : Theme.of(context).colorScheme.errorContainer,
                  onDeleted: () => _remove(address),
                ),
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 160, maxWidth: 320),
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration.collapsed(hintText: ''),
                  onChanged: (text) {
                    if (text.endsWith(',') || text.endsWith(';')) _commit();
                  },
                  onSubmitted: (_) {
                    onSubmit(); // selects the highlighted suggestion, if any
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) return;
                      _commit();
                      focusNode.requestFocus();
                    });
                  },
                ),
              ),
            ],
          ),
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420, maxHeight: 240),
              child: ListView(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                children: [
                  for (final option in options)
                    Builder(builder: (context) {
                      final highlighted =
                          AutocompleteHighlightedOption.of(context) ==
                              options.toList().indexOf(option);
                      if (highlighted) {
                        // Keep the keyboard-highlighted option on screen.
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (context.mounted) {
                            Scrollable.ensureVisible(context, alignment: 0.5);
                          }
                        });
                      }
                      return ListTile(
                        dense: true,
                        selected: highlighted,
                        title: Text(option),
                        onTap: () => onSelected(option),
                      );
                    }),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
