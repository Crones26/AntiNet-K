import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_service/state.dart';
import 'package:vpn_service/vpn_service.dart';
import 'package:karing/app/utils/singbox_config_migration.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('vpn_service_plugin');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('Official Android channel state ordinals and permission arguments', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'getCurrentState') return 3;
      return null;
    });
    expect(await FlutterVpnService.currentState, FlutterVpnServiceState.connected);
    expect(await FlutterVpnService.installService(), isNull);
    expect(calls.last.method, 'install');
    expect(calls.last.arguments, isEmpty);
    await FlutterVpnService.setExcludeFromRecents(true);
    expect(calls.last.arguments, {'exclude': true});
  });

  test('Start and restart retain the original native argument contract', () async {
    final dir = Directory('build/test-private/bridge')..createSync(recursive: true);
    final file = File('${dir.path}/service-config.json')..writeAsStringSync('{}');
    addTearDown(() { file.deleteSync(); });
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async { calls.add(call); return null; });
    FlutterVpnService.prepareConfig(config: VpnServiceConfig(), tunnelServicePath: '', configFilePath: file.path);
    expect((await FlutterVpnService.start(const Duration(seconds: 20))).type, VpnServiceWaitType.done);
    expect(calls.last.method, 'start');
    expect(calls.last.arguments, {'prepare': true, 'configFilePath': file.path, 'timeoutInSeconds': 20});
    expect(calls.map((call) => call.method), ['install', 'start']);
    await FlutterVpnService.restart(const Duration(seconds: 25));
    expect(calls.last.method, 'restart');
    expect(calls.last.arguments['timeoutInSeconds'], 25);
    expect(calls.map((call) => call.method), ['install', 'start', 'install', 'restart']);
  });

  test('Start waits for the actual Android permission result', () async {
    final file = File('build/test-private/permission.json')..parent.createSync(recursive: true);
    file.writeAsStringSync('{}');
    addTearDown(file.deleteSync);
    final consent = Completer<String?>();
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'install') return consent.future;
      return null;
    });
    FlutterVpnService.prepareConfig(config: VpnServiceConfig(), tunnelServicePath: '', configFilePath: file.path);
    final start = FlutterVpnService.start(const Duration(seconds: 20));
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['install']);
    consent.complete(null);
    expect((await start).type, VpnServiceWaitType.done);
    expect(calls, ['install', 'start']);
  });

  test('Denied permission never starts core; a later explicit attempt may retry', () async {
    final file = File('build/test-private/denied.json')..parent.createSync(recursive: true);
    file.writeAsStringSync('{}');
    addTearDown(file.deleteSync);
    var denied = true;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return call.method == 'install' && denied ? 'permission denied' : null;
    });
    FlutterVpnService.prepareConfig(config: VpnServiceConfig(), tunnelServicePath: '', configFilePath: file.path);
    final rejected = await FlutterVpnService.start(const Duration(seconds: 20));
    expect(rejected.type, VpnServiceWaitType.error);
    expect(rejected.err?.message, 'permission denied');
    expect(calls, ['install']);
    denied = false;
    expect((await FlutterVpnService.start(const Duration(seconds: 20))).type, VpnServiceWaitType.done);
    expect(calls, ['install', 'install', 'start']);
  });

  test('Revoked restart permission and platform errors do not reach native restart', () async {
    final file = File('build/test-private/revoked.json')..parent.createSync(recursive: true);
    file.writeAsStringSync('{}');
    addTearDown(file.deleteSync);
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      throw PlatformException(code: 'permission', message: 'VPN permission unavailable');
    });
    FlutterVpnService.prepareConfig(config: VpnServiceConfig(), tunnelServicePath: '', configFilePath: file.path);
    final result = await FlutterVpnService.restart(const Duration(seconds: 20));
    expect(result.type, VpnServiceWaitType.error);
    expect(result.err?.message, 'VPN permission unavailable');
    expect(calls, ['install']);
  });

  test('A native timeout remains a timeout and does not retry another route', () async {
    final file = File('build/test-private/timeout.json')..parent.createSync(recursive: true);
    file.writeAsStringSync('{}');
    addTearDown(file.deleteSync);
    var count = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'install') return null;
      count++;
      return 'start: startService timeout';
    });
    FlutterVpnService.prepareConfig(config: VpnServiceConfig(), tunnelServicePath: '', configFilePath: file.path);
    expect((await FlutterVpnService.start(const Duration(seconds: 1))).type, VpnServiceWaitType.timeout);
    expect(count, 1);
  });

  test('Native state callback uses a MethodChannel and the state map', () async {
    final received = Completer<FlutterVpnServiceState>();
    FlutterVpnService.onStateChanged((state, _) { if (!received.isCompleted) received.complete(state); });
    final response = Completer<void>();
    messenger.handlePlatformMessage('vpn_service_plugin_states',
      const StandardMethodCodec().encodeMethodCall(const MethodCall('stateChanged', {'state': 4})),
      (_) => response.complete());
    await response.future;
    expect(await received.future, FlutterVpnServiceState.reasserting);
  });

  test('Android service config includes required permission and user lock policy', () {
    final config = VpnServiceConfig()..wake_lock = true;
    expect(config.toJson()['prepare'], isTrue);
    expect(config.toJson()['wake_lock'], isTrue);
    expect(config.toJson()['work_dir'], isEmpty);
    final restored = VpnServiceConfig()..fromJson(config.toJson());
    expect(restored.wake_lock, isTrue);
  });
  test('Modern DNS does not detour to an empty direct outbound', () {
    final config = migrateSingboxConfig({
      'outbounds': [{'type': 'direct', 'tag': 'direct_out'}],
      'dns': {'servers': [{'tag': 'resolver', 'address': '8.8.8.8', 'detour': 'direct_out'}]},
    });
    expect((config['dns']['servers'] as List).first.containsKey('detour'), isFalse);
  });
}
