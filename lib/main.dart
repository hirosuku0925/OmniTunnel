import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:openvpn_flutter/openvpn_flutter.dart';

import 'desktop_openvpn_controller.dart';

void main() {
  runApp(const OmniTunnelApp());
}

class OmniTunnelApp extends StatelessWidget {
  const OmniTunnelApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seedColor = Color(0xFF087E78);

    return MaterialApp(
      title: 'OmniTunnel',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: seedColor,
          surface: const Color(0xFFF5F8F7),
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF5F8F7),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF5F8F7),
          surfaceTintColor: Colors.transparent,
        ),
      ),
      home: const TunnelHomePage(),
    );
  }
}

class TunnelHomePage extends StatefulWidget {
  const TunnelHomePage({super.key});

  @override
  State<TunnelHomePage> createState() => _TunnelHomePageState();
}

class _TunnelHomePageState extends State<TunnelHomePage> {
  final _configController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  OpenVPN? _openVpn;
  DesktopOpenVpnController? _desktopOpenVpn;
  VPNStage _stage = VPNStage.disconnected;
  VpnStatus? _vpnStatus;
  String? _configFileName;
  String? _configFilePath;
  String? _initializationError;
  bool _isSupportedPlatform = false;
  bool _isAndroid = false;
  bool _isDesktop = false;
  bool _isInitialized = false;
  bool _isInitializing = false;

  @override
  void initState() {
    super.initState();
    _isAndroid = defaultTargetPlatform == TargetPlatform.android;
    _isDesktop = defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;
    _isSupportedPlatform = _isAndroid || _isDesktop;
    if (_isAndroid) {
      _openVpn = OpenVPN(
        onVpnStatusChanged: _onVpnStatusChanged,
        onVpnStageChanged: _onVpnStageChanged,
      );
      _initializeVpn();
    } else if (_isDesktop) {
      _desktopOpenVpn = DesktopOpenVpnController(
        onStateChanged: _onDesktopVpnStateChanged,
        onLog: debugPrint,
      );
    }
  }

  Future<void> _initializeVpn() async {
    setState(() => _isInitializing = true);
    try {
      await _openVpn!.initialize();
      if (mounted) setState(() => _isInitialized = true);
    } catch (error) {
      if (mounted) setState(() => _initializationError = error.toString());
    } finally {
      if (mounted) setState(() => _isInitializing = false);
    }
  }

  void _onVpnStatusChanged(VpnStatus? status) {
    if (mounted) setState(() => _vpnStatus = status);
  }

  void _onVpnStageChanged(VPNStage stage, String _) {
    if (mounted) setState(() => _stage = stage);
  }

  void _onDesktopVpnStateChanged(DesktopVpnState state) {
    final stage = switch (state) {
      DesktopVpnState.connecting => VPNStage.connecting,
      DesktopVpnState.connected => VPNStage.connected,
      DesktopVpnState.disconnecting => VPNStage.disconnecting,
      DesktopVpnState.disconnected => VPNStage.disconnected,
      DesktopVpnState.error => VPNStage.error,
    };
    if (mounted) setState(() => _stage = stage);
  }

  Future<void> _pickConfigFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['ovpn'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;

      final selectedFile = result.files.single;
      final bytes = selectedFile.bytes;
      if (bytes == null) {
        throw const FormatException('設定ファイルを読み込めませんでした。');
      }

      _configController.text = utf8.decode(bytes);
      setState(() {
        _configFileName = selectedFile.name;
        _configFilePath = selectedFile.path;
      });
    } on Object catch (error) {
      _showMessage('設定ファイルを開けませんでした: $error');
    }
  }

  Future<void> _handleConnectionButton() async {
    if (_stage == VPNStage.connected || _isConnecting) {
      if (_isDesktop) {
        _desktopOpenVpn?.disconnect();
      } else {
        _openVpn?.disconnect();
      }
      return;
    }

    final config = _configController.text.trim();
    if (config.isEmpty || (_isAndroid && !_isInitialized)) return;

    setState(() => _stage = VPNStage.prepare);
    try {
      if (_isDesktop) {
        await _desktopOpenVpn!.connect(
          configText: config,
          configFilePath: _configFilePath,
          username: _usernameController.text.trim().isEmpty
              ? null
              : _usernameController.text.trim(),
          password: _passwordController.text.isEmpty
              ? null
              : _passwordController.text,
        );
      } else if (_isAndroid) {
        final permissionGranted = await _openVpn!.requestPermissionAndroid();
        if (!permissionGranted) {
          if (mounted) setState(() => _stage = VPNStage.disconnected);
          return;
        }
        await _openVpn!.connect(
          config,
          'OmniTunnel',
          username: _usernameController.text.trim().isEmpty
              ? null
              : _usernameController.text.trim(),
          password: _passwordController.text.isEmpty
              ? null
              : _passwordController.text,
        );
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _stage = VPNStage.error);
        _showMessage('VPN に接続できませんでした: $error');
      }
    }
  }

  bool get _isConnecting =>
      _stage != VPNStage.disconnected &&
      _stage != VPNStage.connected &&
      _stage != VPNStage.error &&
      _stage != VPNStage.denied;

  String get _stageLabel => switch (_stage) {
        VPNStage.connected => 'Connected',
        VPNStage.disconnected => 'Disconnected',
        VPNStage.denied => 'Permission denied',
        VPNStage.error => 'Connection error',
        VPNStage.disconnecting => 'Disconnecting',
        _ => 'Connecting',
      };

  Color get _stageColor => switch (_stage) {
        VPNStage.connected => const Color(0xFF087E78),
        VPNStage.error || VPNStage.denied => const Color(0xFFB33A3A),
        VPNStage.disconnected => const Color(0xFF697775),
        _ => const Color(0xFFB46B16),
      };

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _desktopOpenVpn?.dispose();
    _configController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isConnected = _stage == VPNStage.connected;
    final canConnect = _isSupportedPlatform &&
        (!_isAndroid || _isInitialized) &&
        _configController.text.trim().isNotEmpty &&
        !_isInitializing;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 24,
        title: const Row(
          children: [
            Icon(Icons.shield_outlined, color: Color(0xFF087E78)),
            SizedBox(width: 10),
            Text('OmniTunnel', style: TextStyle(fontWeight: FontWeight.w700)),
          ],
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
              children: [
                _buildConnectionPanel(isConnected, canConnect),
                const SizedBox(height: 32),
                _buildConfigurationSection(),
                if (!_isSupportedPlatform) ...[
                  const SizedBox(height: 20),
                  _buildNotice(
                    'OmniTunnel は Android、Windows、macOS、Linux を対象としています。',
                    Icons.desktop_windows_outlined,
                  ),
                ],
                if (_initializationError != null) ...[
                  const SizedBox(height: 12),
                  _buildNotice(
                    'VPN の初期化に失敗しました: $_initializationError',
                    Icons.error_outline,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildConnectionPanel(bool isConnected, bool canConnect) {
    final buttonLabel = isConnected
        ? 'Disconnect'
        : _isConnecting
            ? 'Cancel connection'
            : 'Connect';

    return Column(
      children: [
        const SizedBox(height: 12),
        Container(
          width: 88,
          height: 88,
          decoration: BoxDecoration(
            color: _stageColor.withAlpha(28),
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.shield_rounded, size: 42, color: _stageColor),
        ),
        const SizedBox(height: 18),
        Text(
          _stageLabel,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: _stageColor,
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 6),
        Text(
          isConnected
              ? '通信は暗号化されています'
              : _isInitializing
                  ? 'VPN サービスを準備しています'
                  : '接続先の設定を読み込んでください',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: const Color(0xFF687572),
              ),
          textAlign: TextAlign.center,
        ),
        if (isConnected && _vpnStatus?.duration != null) ...[
          const SizedBox(height: 8),
          Text('接続時間  ${_vpnStatus!.duration}'),
        ],
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          height: 58,
          child: FilledButton.icon(
            onPressed: (canConnect || isConnected || _isConnecting)
                ? _handleConnectionButton
                : null,
            icon: Icon(isConnected || _isConnecting
                ? Icons.link_off_rounded
                : Icons.vpn_key_rounded),
            label: Text(buttonLabel),
            style: FilledButton.styleFrom(
              backgroundColor: isConnected
                  ? const Color(0xFFB33A3A)
                  : const Color(0xFF087E78),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              textStyle: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildConfigurationSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'VPN configuration',
          style: Theme.of(context)
              .textTheme
              .titleLarge
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _pickConfigFile,
          icon: const Icon(Icons.folder_open_outlined),
          label: Text(_configFileName ?? 'Choose .ovpn file'),
          style: OutlinedButton.styleFrom(
            alignment: Alignment.centerLeft,
            minimumSize: const Size(double.infinity, 48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _configController,
          minLines: 5,
          maxLines: 9,
          onChanged: (_) {
            _configFilePath = null;
            setState(() {});
          },
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          decoration: InputDecoration(
            hintText: 'または .ovpn の内容をここに貼り付け',
            alignLabelWithHint: true,
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFFD5DEDB)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFFD5DEDB)),
            ),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _usernameController,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Username (optional)',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.person_outline),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _passwordController,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Password (optional)',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.lock_outline),
          ),
        ),
      ],
    );
  }

  Widget _buildNotice(String message, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFE9EFED),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: const Color(0xFF53625E)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: Color(0xFF40504C)),
            ),
          ),
        ],
      ),
    );
  }
}
