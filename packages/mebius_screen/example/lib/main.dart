import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mebius_screen/mebius_screen.dart';

void main() => runApp(const MaterialApp(home: AgentPage()));

/// Enroll once, then stay online. A real agent adds the tray icon and
/// notifications the integration guide requires; this one shows status inline.
class AgentPage extends StatefulWidget {
  const AgentPage({super.key});

  @override
  State<AgentPage> createState() => _AgentPageState();
}

class _AgentPageState extends State<AgentPage> {
  final _engine = TextEditingController(text: 'https://stream.mebius.io');
  final _code = TextEditingController();
  MebiusScreenAgent? _agent;
  bool? _enrolled;
  String _status = 'Offline';

  MebiusScreenAgent _agentFor(String url) => _agent ??= MebiusScreenAgent(
        engineUrl: Uri.parse(url),
        credentials: MebiusSecureCredentialStore(),
      )
        ..onSession.listen((s) => _set(s.isControl
            ? 'Your screen is being CONTROLLED by ${s.userId}'
            : 'Your screen is being viewed by ${s.userId}'))
        ..onSessionEnded.listen((_) => _set('Online'))
        ..onError.listen((e) => _set('Error: ${e.message}'));

  @override
  void initState() {
    super.initState();
    unawaited(
      MebiusSecureCredentialStore()
          .read()
          .then((c) => setState(() => _enrolled = c != null)),
    );
  }

  void _set(String s) => mounted ? setState(() => _status = s) : null;

  Future<void> _enroll() async {
    try {
      await _agentFor(_engine.text).enroll(
        code: _code.text.trim(),
        name: Platform.localHostname,
        os: Platform.operatingSystem,
      );
      setState(() => _enrolled = true);
    } on MebiusError catch (e) {
      _set('Enroll failed: ${e.message}');
    }
  }

  Future<void> _connect() async {
    await _agentFor(_engine.text).connect();
    _set('Online');
  }

  Future<void> _disconnect() async {
    await _agent?.disconnect();
    _set('Offline');
  }

  @override
  void dispose() {
    unawaited(_agent?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mebius screen agent')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            TextField(
              controller: _engine,
              decoration: const InputDecoration(labelText: 'Engine URL'),
            ),
            if (_enrolled == false) ...[
              TextField(
                controller: _code,
                decoration: const InputDecoration(labelText: 'Enroll code'),
              ),
              FilledButton(onPressed: _enroll, child: const Text('Enroll')),
            ],
            if (_enrolled == true)
              Row(
                spacing: 12,
                children: [
                  FilledButton(onPressed: _connect, child: const Text('Go online')),
                  OutlinedButton(
                    onPressed: _disconnect,
                    child: const Text('Go offline'),
                  ),
                ],
              ),
            Text(_status, style: Theme.of(context).textTheme.titleMedium),
          ],
        ),
      ),
    );
  }
}
