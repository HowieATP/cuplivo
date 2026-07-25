import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/custom_key_value_editor.dart';

class ProviderCustomRequestPage extends StatefulWidget {
  const ProviderCustomRequestPage({
    super.key,
    required this.providerKey,
    required this.providerDisplayName,
  });

  final String providerKey;
  final String providerDisplayName;

  @override
  State<ProviderCustomRequestPage> createState() =>
      _ProviderCustomRequestPageState();
}

class _ProviderCustomRequestPageState extends State<ProviderCustomRequestPage> {
  late List<Map<String, String>> _headers;
  late List<Map<String, String>> _body;

  @override
  void initState() {
    super.initState();
    final cfg = context.read<SettingsProvider>().getProviderConfig(
      widget.providerKey,
      defaultName: widget.providerDisplayName,
    );
    _headers = List<Map<String, String>>.from(cfg.customHeaders);
    _body = List<Map<String, String>>.from(cfg.customBody);
  }

  Future<void> _save() async {
    final sp = context.read<SettingsProvider>();
    final old = sp.getProviderConfig(
      widget.providerKey,
      defaultName: widget.providerDisplayName,
    );
    await sp.setProviderConfig(
      widget.providerKey,
      old.copyWith(
        customHeaders: _headers.isEmpty ? const [] : _headers,
        customBody: _body.isEmpty ? const [] : _body,
      ),
    );
  }

  void _addHeader() {
    setState(() => _headers.add({'name': '', 'value': ''}));
    _save();
  }

  void _removeHeader(int index) {
    if (index < 0 || index >= _headers.length) return;
    setState(() => _headers.removeAt(index));
    _save();
  }

  void _updateHeader(int index, String name, String value) {
    if (index < 0 || index >= _headers.length) return;
    setState(() {
      _headers[index] = {'name': name, 'value': value};
    });
    _save();
  }

  void _addBody() {
    setState(() => _body.add({'key': '', 'value': ''}));
    _save();
  }

  void _removeBody(int index) {
    if (index < 0 || index >= _body.length) return;
    setState(() => _body.removeAt(index));
    _save();
  }

  void _updateBody(int index, String key, String value) {
    if (index < 0 || index >= _body.length) return;
    setState(() {
      _body[index] = {'key': key, 'value': value};
    });
    _save();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: Icon(Lucide.ArrowLeft, color: cs.primary),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          l10n.providerCustomRequestTitle,
          style: TextStyle(color: cs.onSurface),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 16),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: CustomKeyValueEditor(
              title: l10n.providerCustomRequestHeaders,
              keyMode: KeyMode.header,
              entries: _headers,
              onAdd: _addHeader,
              onRemove: _removeHeader,
              onUpdate: _updateHeader,
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: CustomKeyValueEditor(
              title: l10n.providerCustomRequestBody,
              keyMode: KeyMode.body,
              entries: _body,
              onAdd: _addBody,
              onRemove: _removeBody,
              onUpdate: _updateBody,
            ),
          ),
        ],
      ),
    );
  }
}
