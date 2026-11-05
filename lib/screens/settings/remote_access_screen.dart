import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/native_url_launcher.dart';
import '../../services/web_server_service.dart';

/// Settings for the embedded web server that exposes the dashboard, live PID
/// values, charging history and debug log to a browser on the LAN / Tailscale.
class RemoteAccessScreen extends StatefulWidget {
  const RemoteAccessScreen({super.key});

  @override
  State<RemoteAccessScreen> createState() => _RemoteAccessScreenState();
}

class _RemoteAccessScreenState extends State<RemoteAccessScreen> {
  final _service = WebServerService.instance;
  final _portController = TextEditingController();
  final _tokenController = TextEditingController();

  bool _enabled = false;
  bool _running = false;
  bool _busy = false;
  String? _error;
  List<String> _urls = const [];

  @override
  void initState() {
    super.initState();
    _enabled = _service.isEnabled;
    _running = _service.isRunning;
    _error = _service.lastError;
    _portController.text = _service.port.toString();
    _tokenController.text = _service.token;
    _refreshUrls();
  }

  @override
  void dispose() {
    _portController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _refreshUrls() async {
    final urls = await _service.getUrls();
    if (!mounted) return;
    setState(() => _urls = urls);
  }

  Future<void> _setEnabled(bool value) async {
    setState(() => _busy = true);
    await _service.setEnabled(value);
    if (!mounted) return;
    setState(() {
      _enabled = value;
      _running = _service.isRunning;
      _error = _service.lastError;
      _busy = false;
    });
    await _refreshUrls();
  }

  Future<void> _savePort() async {
    final parsed = int.tryParse(_portController.text.trim());
    if (parsed == null || parsed < 1024 || parsed > 65535) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Port must be between 1024 and 65535')),
      );
      return;
    }

    setState(() => _busy = true);
    await _service.setPort(parsed);
    if (!mounted) return;
    setState(() {
      _running = _service.isRunning;
      _error = _service.lastError;
      _busy = false;
    });
    await _refreshUrls();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Port saved')),
      );
    }
  }

  Future<void> _saveToken() async {
    await _service.setToken(_tokenController.text);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_tokenController.text.trim().isEmpty
            ? 'Token removed — anyone on the network can view the dashboard'
            : 'Access token saved'),
      ),
    );
  }

  Future<void> _copy(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Copied $text')),
        );
      }
    } catch (e) {
      // Clipboard is unavailable on some AI boxes.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not copy: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Remote Access')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.public),
                  title: const Text('Web server'),
                  subtitle: Text(_enabled
                      ? 'Serving the dashboard to your network'
                      : 'Off — the dashboard is not reachable from a browser'),
                  value: _enabled,
                  onChanged: _busy ? null : _setEnabled,
                ),
                if (_running) ...[
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.check_circle, color: Colors.green),
                    title: const Text('Running'),
                    subtitle: Text('Port ${_service.port} · '
                        '${_service.startedAt == null ? '' : 'since ${TimeOfDay.fromDateTime(_service.startedAt!).format(context)}'}'),
                  ),
                  for (final url in _urls)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.link),
                      title: Text(url),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Copy address',
                            icon: const Icon(Icons.copy, size: 20),
                            onPressed: () => _copy(url),
                          ),
                          IconButton(
                            tooltip: 'Open in browser',
                            icon: const Icon(Icons.open_in_browser, size: 20),
                            onPressed: () => NativeUrlLauncher.openUrl(url),
                          ),
                        ],
                      ),
                    ),
                ],
                if (_error != null)
                  ListTile(
                    leading: const Icon(Icons.error_outline, color: Colors.red),
                    title: const Text('Could not start the server'),
                    subtitle: Text(_error!),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Port', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _portController,
                          keyboardType: TextInputType.number,
                          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            isDense: true,
                            helperText: 'Default 8080',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.tonal(
                        onPressed: _busy ? null : _savePort,
                        child: const Text('Save'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text('Access token', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(
                    'Optional. When set, every API request and the browser UI '
                    'need the token. Leave empty for an open dashboard on your '
                    'own network.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _tokenController,
                          obscureText: true,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            isDense: true,
                            hintText: 'No token',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.tonal(
                        onPressed: _busy ? null : _saveToken,
                        child: const Text('Save'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('How it works', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Text(
                    'While XPCarData is running it serves the same pages and '
                    'fields you see on the dashboard — live PID values, cell '
                    'voltages, charging history and the debug log — to any '
                    'browser that can reach this device.\n\n'
                    'On your home Wi-Fi use the address above. Away from home, '
                    'open the same address through Tailscale instead of exposing '
                    'the car to the internet.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
