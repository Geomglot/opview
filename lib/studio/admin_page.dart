// The app's settings: which comma, how to reach it, the comma Connect sign-in, where clips go and the stored drives

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:opview/studio/desktop.dart';
import 'package:opview/studio/studio_api.dart';

/// a size in the units a person would use
String sizeLabel(int bytes) =>
    bytes >= 1 << 30 ? '${(bytes / (1 << 30)).toStringAsFixed(1)} GB' : '${(bytes / (1 << 20)).toStringAsFixed(0)} MB';

class AdminPage extends StatefulWidget {
  final StudioApi api;
  const AdminPage({super.key, required this.api});
  @override
  State<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<AdminPage> {
  Map<String, dynamic>? _s;
  String? _error;
  final _host = TextEditingController();
  final _token = TextEditingController();
  final _folder = TextEditingController();
  String? _hostResult;
  bool _hostOk = false, _checking = false, _finding = false, _tokenBusy = false;
  List<dynamic>? _found;
  String? _tokenResult;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _show(Map<String, dynamic> s) {
    setState(() => _s = s);
    _host.text = s['host'] as String;
    _folder.text = s['output_dir'] as String;
  }

  Future<void> _load() async {
    try {
      _show(await widget.api.settings());
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  Future<void> _change(Map<String, Object?> changes) async => _show(await widget.api.changeSettings(changes));

  Future<void> _testHost() async {
    setState(() {
      _checking = true;
      _hostResult = null;
    });
    final r = await widget.api.checkHost(_host.text);
    final dongle = _s?['dongle'];
    final other = r['ok'] == true && dongle != null && r['dongle'] != dongle;
    setState(() {
      _checking = false;
      _hostOk = r['ok'] == true;
      _hostResult = _hostOk
          ? 'Connected to comma ${r['dongle']}${other ? '. That is not the device chosen above.' : ''}'
          : '${r['error']}';
    });
    if (_hostOk) await _change({'host': _host.text});
  }

  Future<void> _find() async {
    setState(() {
      _finding = true;
      _found = null;
    });
    final found = await widget.api.findComma();
    setState(() {
      _finding = false;
      _found = found;
    });
  }

  Future<void> _useAddress(String address) async {
    _host.text = address;
    await _testHost();
    setState(() => _found = null);
  }

  Future<void> _createKey() async {
    await widget.api.createSshKey();
    await _load();
  }

  Future<void> _saveToken() async {
    setState(() {
      _tokenBusy = true;
      _tokenResult = null;
    });
    try {
      await widget.api.saveToken(_token.text);
      _token.clear();
      await _load();
      setState(() => _tokenResult = 'Saved.');
    } catch (e) {
      setState(() => _tokenResult = '$e');
    } finally {
      setState(() => _tokenBusy = false);
    }
  }

  // the computer's own folder dialog; no plugin needed. On Windows the app's window code opens it
  // (windows/runner/flutter_window.cpp)
  Future<void> _chooseFolder() async {
    if (Platform.isWindows) {
      final chosen = await const MethodChannel('oprivview/window').invokeMethod<String>('chooseFolder');
      if (chosen != null) await _change({'output_dir': chosen});
      return;
    }
    final r = await Process.run('osascript', ['-e', 'POSIX path of (choose folder with prompt "Save clips in")']);
    if (r.exitCode == 0) await _change({'output_dir': (r.stdout as String).trim()});
  }

  Future<void> _clearCache() async {
    final sure = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
              title: const Text('Clear stored drives?'),
              content: const Text('Drives are downloaded again when next used. A drive that has since been deleted from the comma '
                  'and comma Connect cannot be brought back. Your finished MP4 clips are not touched.'),
              actions: [
                TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('Keep them')),
                FilledButton(onPressed: () => Navigator.of(c).pop(true), child: const Text('Clear')),
              ],
            ));
    if (sure != true) return;
    try {
      await widget.api.clearCache();
      await _load();
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  Widget _section(String title, List<Widget> children) => Padding(
      padding: const EdgeInsets.only(bottom: 28),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ...children,
      ]));

  Widget _note(String text, {Color? color}) => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: SelectableText(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color)));

  Widget _deviceSection(Map<String, dynamic> s) {
    final devices = (s['devices'] as List).cast<Map<String, dynamic>>();
    return _section('comma device', [
      if (devices.isEmpty)
        _note('Sign in to comma Connect below to choose from the devices on your account.')
      else
        DropdownButton<String>(
          value: s['dongle'] as String?,
          items: [for (final d in devices) DropdownMenuItem(value: d['dongle'] as String, child: Text(d['name'] as String))],
          onChanged: (d) => _change({'dongle': d}),
        ),
    ]);
  }

  Widget _networkSection() => _section('comma on the local network', [
        Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SizedBox(
              width: 280,
              child: TextField(
                  controller: _host,
                  decoration: const InputDecoration(labelText: 'Address or SSH name', hintText: '192.168.1.20', isDense: true))),
          OutlinedButton(onPressed: _checking ? null : _testHost, child: Text(_checking ? 'Testing...' : 'Test and use')),
          OutlinedButton(onPressed: _finding ? null : _find, child: Text(_finding ? 'Searching...' : 'Find on this network')),
        ]),
        if (_hostResult != null) _note(_hostResult!, color: _hostOk ? Colors.greenAccent : Colors.redAccent),
        if (_found != null && _found!.isEmpty) _note('Nothing on this network answered on the SSH port. Is the comma on, with SSH enabled?'),
        if (_found != null)
          for (final f in _found!)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(f['address'] as String),
              subtitle: Text(f['comma'] == true ? 'comma ${f['dongle']}' : 'Has SSH, but is not a comma $_thisComputer can log in to'),
              trailing: TextButton(onPressed: () => _useAddress(f['address'] as String), child: const Text('Use')),
            ),
      ]);

  /// what the settings call the computer the app runs on
  static String get _thisComputer => Platform.isWindows ? 'this computer' : 'this Mac';
  static String _capital(String s) => '${s[0].toUpperCase()}${s.substring(1)}';

  Widget _sshSection(Map<String, dynamic> s) {
    final key = s['key'] as Map<String, dynamic>;
    final public = key['public_key'] as String?;
    return _section('SSH setup', [
      if (public == null) ...[
        _note('${_capital(_thisComputer)} has no SSH key yet. The comma uses one to let $_thisComputer in.'),
        const SizedBox(height: 8),
        OutlinedButton(onPressed: _createKey, child: const Text('Create a key')),
      ] else ...[
        _note('${_capital(_thisComputer)}\'s public key, ${key['path']}. It is safe to share.'),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(
              child: SelectableText(public,
                  maxLines: 2, style: TextStyle(fontFamily: Platform.isWindows ? 'Consolas' : 'Menlo', fontSize: 11))),
          TextButton(onPressed: () => Clipboard.setData(ClipboardData(text: public)), child: const Text('Copy')),
        ]),
        _note('If the comma does not let $_thisComputer in:\n'
            '1. Copy the key and add it at github.com, under Settings, SSH and GPG keys.\n'
            '2. On the comma, open Settings, Developer, turn on Enable SSH, and under SSH Keys enter your GitHub username.\n'
            '3. Press Test and use above.'),
        Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
                onPressed: () => openOnDesktop('https://github.com/settings/keys'), child: const Text('Open GitHub SSH keys'))),
      ],
    ]);
  }

  Widget _tokenSection(Map<String, dynamic> s) {
    final token = s['token'] as Map<String, dynamic>?;
    final state = token?['state'];
    final expires = token?['expires'] as int?;
    final until = expires == null ? '' : ' until ${DateTime.fromMillisecondsSinceEpoch(expires * 1000).toString().substring(0, 10)}';
    return _section('comma Connect sign-in', [
      _note(switch (state) {
        'ok' => 'Signed in$until.',
        'expired' => 'The sign-in has expired. Paste a new token below.',
        _ => 'Not signed in. Drives on comma Connect need a token. Public drives do not.',
      }, color: state == 'ok' ? Colors.greenAccent : Colors.orangeAccent),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
            child: TextField(
                controller: _token,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'New token', isDense: true))),
        const SizedBox(width: 12),
        OutlinedButton(onPressed: _tokenBusy ? null : _saveToken, child: Text(_tokenBusy ? 'Checking...' : 'Save')),
        const SizedBox(width: 4),
        TextButton(onPressed: () => openOnDesktop('https://jwt.comma.ai'), child: const Text('Get a token')),
      ]),
      if (_tokenResult != null) _note(_tokenResult!),
    ]);
  }

  Widget _outputSection() => _section('Where clips are saved', [
        Row(children: [
          Expanded(
              child: TextField(
                  controller: _folder,
                  onSubmitted: (v) => _change({'output_dir': v}),
                  decoration: const InputDecoration(labelText: 'Folder', isDense: true))),
          const SizedBox(width: 12),
          TextButton(onPressed: _chooseFolder, child: const Text('Choose...')),
          TextButton(onPressed: () => _change({'output_dir': _folder.text}), child: const Text('Save')),
        ]),
      ]);

  Widget _storageSection(Map<String, dynamic> s) => _section('Stored drives', [
        _note('Downloaded logs and video take ${sizeLabel(s['cache_bytes'] as int)} in ${s['cache_path']}. '
            'Keeping them makes a drive quicker to open again.'),
        const SizedBox(height: 8),
        OutlinedButton(onPressed: _clearCache, child: const Text('Clear stored drives')),
      ]);

  @override
  Widget build(BuildContext context) {
    final s = _s;
    return Scaffold(
      appBar: AppBar(title: const Text('App settings')),
      body: s == null
          ? Center(child: _error != null ? Text(_error!, style: const TextStyle(color: Colors.red)) : const CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Center(
                  child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        if (_error != null) _note(_error!, color: Colors.redAccent),
                        _deviceSection(s),
                        _networkSection(),
                        _sshSection(s),
                        _tokenSection(s),
                        _outputSection(),
                        _storageSection(s),
                      ])))),
    );
  }
}
