import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'proxy_manager.dart';
import 'state.dart';
import 'vpn_service_platform_interface.dart';

export 'vpn_service_platform_interface.dart';

/// Android bridge for the unchanged native plugin in the official 2802 APK.
/// The channel names, arguments and state ordinals are verified against that
/// APK's io.nebula.vpn_service.VpnServicePlugin, not the Karing+ replacement.
class FlutterVpnService {
  static const _methods = MethodChannel('vpn_service_plugin');
  static const _states = MethodChannel('vpn_service_plugin_states');
  static String _configPath = '';
  static bool _listening = false;
  static void Function(FlutterVpnServiceState, Map<String, String>)? _callback;

  static FlutterVpnServiceState _decodeState(Object? value) {
    if (value is! int || value < 0 || value >= FlutterVpnServiceState.values.length) {
      throw FormatException('Invalid native VPN state: $value');
    }
    return FlutterVpnServiceState.values[value];
  }

  static void onStateChanged(
    void Function(FlutterVpnServiceState, Map<String, String>) callback,
  ) {
    _callback = callback;
    if (_listening) return;
    _listening = true;
    _states.setMethodCallHandler((call) async {
      if (call.method != 'stateChanged') return;
      final args = call.arguments;
      if (args is! Map) throw const FormatException('Missing native state arguments');
      final state = _decodeState(args['state']);
      final rawParams = args['params'];
      final params = <String, String>{};
      if (rawParams is Map) {
        for (final entry in rawParams.entries) {
          params[entry.key.toString()] = entry.value.toString();
        }
      }
      _callback?.call(state, params);
    });
  }

  static Future<FlutterVpnServiceState> get currentState async =>
      _decodeState(await _methods.invokeMethod<int>('getCurrentState'));

  static void prepareConfig({
    required VpnServiceConfig config,
    required String tunnelServicePath,
    required String configFilePath,
    bool systemExtension = false,
    String bundleIdentifier = '',
    String uiServerAddress = '',
    String uiLocalizedDescription = '',
    List<int> excludePorts = const [],
  }) {
    _configPath = configFilePath;
  }

  static Future<VpnServiceWaitResult> _start(String method, Duration timeout) async {
    if (_configPath.isEmpty || !await File(_configPath).exists()) {
      return VpnServiceWaitResult(VpnServiceWaitType.error,
          VpnServiceResultError('VPN configuration file is missing.'));
    }
    try {
      final error = await _methods.invokeMethod<String>(method, {
        'prepare': true,
        'configFilePath': _configPath,
        'timeoutInSeconds': timeout.inSeconds.clamp(1, 300),
      });
      if (error == null || error.isEmpty) {
        return VpnServiceWaitResult(VpnServiceWaitType.done);
      }
      return VpnServiceWaitResult(
        error.contains('timeout') ? VpnServiceWaitType.timeout : VpnServiceWaitType.error,
        VpnServiceResultError(error),
      );
    } on PlatformException catch (error) {
      return VpnServiceWaitResult(VpnServiceWaitType.error,
          VpnServiceResultError(error.message ?? error.code));
    } on MissingPluginException {
      return VpnServiceWaitResult(VpnServiceWaitType.error,
          VpnServiceResultError('The Android VPN plugin is unavailable.'));
    }
  }

  static Future<VpnServiceWaitResult> start(Duration timeout) => _start('start', timeout);
  static Future<VpnServiceWaitResult> restart(Duration timeout) => _start('restart', timeout);
  static Future<void> stop() => _methods.invokeMethod<void>('stop');

  static Future<VpnServiceResultError?> installService() async {
    final error = await _methods.invokeMethod<String>('install', <String, dynamic>{});
    return error == null || error.isEmpty ? null : VpnServiceResultError(error);
  }

  static Future<VpnServiceResultError?> uninstallService() async {
    final error = await _methods.invokeMethod<String>('uninstall');
    return error == null || error.isEmpty ? null : VpnServiceResultError(error);
  }

  static Future<String> getABIs() async => await _methods.invokeMethod<String>('getABIs') ?? '';
  static Future<String> getSystemVersion() async =>
      await _methods.invokeMethod<String>('getSystemVersion') ?? '';
  static Future<String> clashiApiConnections(bool includeConnections) async =>
      await _methods.invokeMethod<String>('clashiApiConnections', {
        'includeConnections': includeConnections,
      }) ?? '{}';
  static Future<VpnServiceResultError?> setExcludeFromRecents(bool exclude) async {
    final error = await _methods.invokeMethod<String>('setExcludeFromRecents', {'exclude': exclude});
    return error == null || error.isEmpty ? null : VpnServiceResultError(error);
  }

  // Android permissions for always-on VPN are owned by the system settings.
  static Future<void> setAlwaysOn(bool value) async {}
  static Future<Directory?> getAppGroupDirectory(String group) async => null;

  static Never _otherPlatform() => throw UnsupportedError('Desktop/Apple operation in the Android build.');
  static Future<bool> isRunAsAdmin() async => _otherPlatform();
  static Future<void> setSystemProxy(ProxyOption option) async => _otherPlatform();
  static Future<void> cleanSystemProxy() async => _otherPlatform();
  static Future<bool> getSystemProxyEnable(ProxyOption option) async => _otherPlatform();
  static Future<bool> isServiceAuthorized(String servicePath) async => _otherPlatform();
  static Future<VpnServiceResultError?> authorizeService(String servicePath, String password) async => _otherPlatform();
  static void firewallAddApp(String executable, String name) => _otherPlatform();
  static Future<void> firewallAddPorts(List<int> ports, String name) async => _otherPlatform();
  static Future<void> hideDockIcon(bool value) async => _otherPlatform();
  static Future<String?> getProcessList() async => _otherPlatform();
  static Future<Uint8List?> getProcessIcon(String identifier) async => _otherPlatform();
  static Future<void> autoStartDelete(String name) async => _otherPlatform();
  static Future<bool> autoStartIsActive(String name) async => _otherPlatform();
  static Future<void> autoStartCreate(String name, String executable,
      {String processArgs = '', bool runElevated = false}) async => _otherPlatform();
  static Future<void> startTask(String name) async => _otherPlatform();
}
