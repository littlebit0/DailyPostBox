import 'package:flutter/material.dart';

final _addressPattern = RegExp(r'^[^\s@,;<>]+@[^\s@,;<>]+\.[^\s@,;<>]+$');

bool isValidEmailAddress(String value) => _addressPattern.hasMatch(value);

/// Chip input for recipients with async address suggestions.
class RecipientField extends StatefulWidget {
  const RecipientField({
    super.key,
    required this.label,
    required this.errorText,
    required this.suggest,
    required this.onChanged,
  });

  final String label;
  final String errorText;
  final Future<List<String>> Function(String query) suggest;
  final ValueChanged<List<String>> onChanged;

  @override
  State<RecipientField> createState() => RecipientFieldState();
}

class RecipientFieldState extends State<RecipientField> {
  final _focusNode = FocusNode();
  final _addresses = <String>[];
  TextEditingController? _controller;
  int _request = 0;

  /// Commits typed text as a chip; call before sending.
  List<String> commitPending() {
    _commit(_controller?.text ?? '');
    return List.unmodifiable(_addresses);
  }

  bool get hasInvalid => _addresses.any((item) => !isValidEmailAddress(item));

  void _commit(String text) {
    final parts = text
        .split(RegExp(r'[,;\s]+'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty);
    var changed = false;
    for (final part in parts) {
      if (!_addresses.contains(part)) {
        _addresses.add(part);
        changed = true;
      }
    }
    _controller?.clear();
    if (changed) {
      setState(() {});
      widget.onChanged(List.unmodifiable(_addresses));
    }
  }

  void _remove(String address) {
    setState(() => _addresses.remove(address));
    widget.onChanged(List.unmodifiable(_addresses));
  }

  Future<Iterable<String>> _options(TextEditingValue value) async {
    final query = value.text.trim();
    if (query.length < 2) return const [];
    final request = ++_request;
    try {
      final result = await widget.suggest(query);
      if (request != _request) return const [];
      return result.where((item) => !_addresses.contains(item));
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
      textEditingController: _controller ??= TextEditingController(),
      optionsBuilder: _options,
      onSelected: (address) {
        // Defer: RawAutocomplete rewrites the field text right after onSelected.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _commit(address);
          _focusNode.requestFocus();
        });
      },
      fieldViewBuilder: (context, controller, focusNode, onSubmit) {
        return InputDecorator(
          decoration: InputDecoration(
            labelText: widget.label,
            errorText: hasInvalid ? widget.errorText : null,
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
                    if (text.endsWith(',') || text.endsWith(';')) _commit(text);
                  },
                  onSubmitted: (_) {
                    onSubmit(); // selects the highlighted suggestion, if any
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) return;
                      _commit(controller.text);
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
