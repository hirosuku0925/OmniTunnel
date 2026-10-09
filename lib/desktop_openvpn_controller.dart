import 'dart:convert';
import 'dart:io';

enum DesktopVpnState {
  connecting,
  connected,
  disconnecting,
  disconnected,
  error,
}

class DesktopOpenVpnController {
  DesktopOpenVpnController({
    required this.onStateChanged,
    required this.onLog,
  });

  final void Function(DesktopVpnState state) onStateChanged;
  final void Function(String line) onLog;

  Process? _process;
  Directory? _runtimeDirectory;
  bool _disconnectRequested = false;
  bool _isPreparing = false;

  Future<void> connect({
    required String configText,
    String? configFilePath,
    String? username,
    String? password,
  }) async {
    if (_process != null) {
      throw StateError('An OpenVPN process is already running.');
    }
    if ((username?.isNotEmpty ?? false) != (password?.isNotEmpty ?? false)) {
      throw ArgumentError('Username and password must both be provided.');
    }
    if ((username?.contains(RegExp(r'[\r\n]')) ?? false) ||
        (password?.contains(RegExp(r'[\r\n]')) ?? false)) {
      throw ArgumentError('Credentials cannot contain line breaks.');
    }
    final hasCredentials = username?.isNotEmpty ?? false;
    final hasInteractiveAuth = RegExp(
      r'^\s*auth-user-pass\s*(?:#.*)?$',
      caseSensitive: false,
      multiLine: true,
    ).hasMatch(configText);
    if (hasInteractiveAuth && !hasCredentials) {
      throw ArgumentError('This profile requires a username and password.');
    }

    onStateChanged(DesktopVpnState.connecting);
    _disconnectRequested = false;
    _isPreparing = true;
    late final Directory runtimeDirectory;

    try {
      runtimeDirectory = await Directory.systemTemp.createTemp('omnitunnel-');
      _runtimeDirectory = runtimeDirectory;
      if (_disconnectRequested) {
        _isPreparing = false;
        await _removeRuntimeDirectory();
        onStateChanged(DesktopVpnState.disconnected);
        return;
      }
      await _restrictDirectory(runtimeDirectory);
      final configPath =
          '${runtimeDirectory.path}${Platform.pathSeparator}client.ovpn';
      var config = configText;

      if (username?.isNotEmpty ?? false) {
        final credentialsPath =
            '${runtimeDirectory.path}${Platform.pathSeparator}credentials.txt';
        final credentialsFile = File(credentialsPath);
        await credentialsFile.writeAsString('$username\n$password\n',
            flush: true);
        await _restrictFile(credentialsFile);

        final authUserPass = RegExp(
          r'^\s*auth-user-pass(?:\s+.*)?$',
          caseSensitive: false,
          multiLine: true,
        );
        final directive =
            'auth-user-pass "${_quoteConfigPath(credentialsPath)}"';
        config = authUserPass.hasMatch(config)
            ? config.replaceAll(authUserPass, directive)
            : '${config.trimRight()}\n$directive\n';
      }

      await File(configPath).writeAsString(config, flush: true);
      if (_disconnectRequested) {
        _isPreparing = false;
        await _removeRuntimeDirectory();
        onStateChanged(DesktopVpnState.disconnected);
        return;
      }
      final workingDirectory = configFilePath == null
          ? runtimeDirectory.path
          : File(configFilePath).parent.path;
      final process = await Process.start(
        resolveExecutable(),
        ['--config', configPath, '--auth-nocache'],
        workingDirectory: workingDirectory,
        runInShell: false,
      );
      _process = process;
      _isPreparing = false;

      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleOutputLine);
      process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleOutputLine);
      process.exitCode.then((exitCode) => _handleExit(process, exitCode));
      if (_disconnectRequested) {
        if (!process.kill(ProcessSignal.sigint)) {
          process.kill();
        }
      }
    } on Object {
      _isPreparing = false;
      await _removeRuntimeDirectory();
      onStateChanged(DesktopVpnState.error);
      rethrow;
    }
  }

  void disconnect() {
    final process = _process;
    if (process == null) {
      if (_isPreparing) {
        _disconnectRequested = true;
        onStateChanged(DesktopVpnState.disconnecting);
      }
      return;
    }

    _disconnectRequested = true;
    onStateChanged(DesktopVpnState.disconnecting);
    if (!process.kill(ProcessSignal.sigint)) {
      process.kill();
    }
  }

  Future<void> dispose() async {
    disconnect();
  }

  static String resolveExecutable() {
    final override = Platform.environment['OMNITUNNEL_OPENVPN'];
    if (override != null && override.isNotEmpty) return override;

    final appDirectory = File(Platform.resolvedExecutable).parent.path;
    final separator = Platform.pathSeparator;
    final candidates = Platform.isWindows
        ? [
            '$appDirectory${separator}openvpn${separator}openvpn.exe',
            '$appDirectory${separator}openvpn.exe',
            'openvpn.exe',
          ]
        : Platform.isMacOS
            ? [
                '$appDirectory${separator}..${separator}Frameworks${separator}openvpn',
                '$appDirectory${separator}..${separator}Resources${separator}openvpn',
                '/opt/homebrew/sbin/openvpn',
                '/usr/local/sbin/openvpn',
                'openvpn',
              ]
            : [
                '$appDirectory${separator}openvpn${separator}openvpn',
                '$appDirectory${separator}..${separator}lib${separator}omnitunnel${separator}openvpn',
                '/usr/sbin/openvpn',
                '/usr/bin/openvpn',
                'openvpn',
              ];

    return candidates.firstWhere(
      (candidate) =>
          candidate == 'openvpn' ||
          candidate == 'openvpn.exe' ||
          File(candidate).existsSync(),
    );
  }

  void _handleOutputLine(String line) {
    onLog(line);
    if (line.contains('Initialization Sequence Completed')) {
      onStateChanged(DesktopVpnState.connected);
    }
  }

  Future<void> _handleExit(Process process, int exitCode) async {
    if (!identical(_process, process)) return;
    _process = null;
    await _removeRuntimeDirectory();
    onStateChanged(_disconnectRequested || exitCode == 0
        ? DesktopVpnState.disconnected
        : DesktopVpnState.error);
  }

  Future<void> _removeRuntimeDirectory() async {
    final directory = _runtimeDirectory;
    _runtimeDirectory = null;
    if (directory != null && await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  Future<void> _restrictDirectory(Directory directory) async {
    if (Platform.isWindows) return;
    await Process.run('chmod', ['700', directory.path]);
  }

  Future<void> _restrictFile(File file) async {
    if (Platform.isWindows) return;
    await Process.run('chmod', ['600', file.path]);
  }

  String _quoteConfigPath(String path) =>
      path.replaceAll('\\', '/').replaceAll('"', r'\"');
}
