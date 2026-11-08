import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karing/app/modules/service_checks.dart';
import 'package:karing/app/modules/setting_manager.dart';
import 'package:karing/app/modules/verified_servers.dart';
import 'package:karing/app/utils/proxy_conf_utils.dart';
import 'package:karing/screens/antinet_compact_home.dart';

class FakeTransport implements ServiceTransport {
  final completer = Completer<ServiceResult>();
  bool closed = false;
  int? port;
  @override
  Future<ServiceResult> head(Uri uri, ServiceRoute route, int? port, Duration timeout) {
    this.port = port;
    return completer.future;
  }
  @override
  void close() { closed = true; }
}

ProxyConfig server(String tag, {String host = 'example.test', String password = 'test-password'}) =>
  ProxyConfig()..fromJson({'groupid': 'source', 'tag': tag, 'type': 'trojan',
    'server': host, 'server_port': 443, 'password': password,
    'tls': {'enabled': true, 'server_name': 'sni.example.test'}, 'latency': '10'});

void pass(ProxyConfig config) {
  final ticket = VerifiedServers.begin(config);
  VerifiedServers.complete(ticket, config, success: true);
}

void main() {
  setUp(VerifiedServers.reset);
  test('Stored latency cannot qualify a server; only a completed check can', () {
    final config = server('one');
    expect(VerifiedServers.eligible(config), isFalse);
    pass(config);
    expect(VerifiedServers.eligible(config), isTrue);
  });
  test('Changed credentials, stale completions and negative results are rejected', () {
    final config = server('one');
    final old = VerifiedServers.begin(config);
    final current = VerifiedServers.begin(config);
    VerifiedServers.complete(old, config, success: true);
    expect(VerifiedServers.eligible(config), isFalse);
    VerifiedServers.complete(current, config, success: true);
    expect(VerifiedServers.eligible(config), isTrue);
    config.raw['password'] = 'changed';
    expect(VerifiedServers.eligible(config), isFalse);
    final pending = VerifiedServers.begin(config);
    config.raw['tls']['server_name'] = 'changed.example.test';
    VerifiedServers.complete(pending, config, success: true);
    expect(VerifiedServers.eligible(config), isFalse);
    pass(config);
    VerifiedServers.complete(VerifiedServers.begin(config), config, success: false);
    expect(VerifiedServers.eligible(config), isFalse);
  });
  test('Collection preserves manual favorites and native source objects; deduplicates full settings', () {
    final manual = server('manual', host: 'manual.test');
    final first = server('one');
    final duplicate = server('two');
    final differentPassword = server('three', password: 'another');
    final disabled = server('disabled', host: 'disabled.test');
    for (final config in [first, duplicate, differentPassword, disabled]) { pass(config); }
    final favorites = [manual];
    final added = VerifiedServers.collect([first, duplicate, differentPassword, disabled], favorites,
      disabled: {VerifiedServers.key(disabled)});
    expect(added, [first, differentPassword]);
    expect(identical(favorites.first, manual), isTrue);
    expect(identical(favorites[1], first), isTrue);
    expect(first.raw['tls']['server_name'], 'sni.example.test');
    expect(VerifiedServers.collect([first], favorites), isEmpty);
  });
  test('Old verdicts expire and pending checks invalidate previous positives', () {
    final config = server('one');
    final at = DateTime.utc(2026, 1, 1);
    VerifiedServers.complete(VerifiedServers.begin(config), config, success: true, now: at);
    expect(VerifiedServers.eligible(config, now: at.add(const Duration(minutes: 30))), isTrue);
    expect(VerifiedServers.eligible(config, now: at.add(const Duration(hours: 2))), isFalse);
    VerifiedServers.begin(config);
    expect(VerifiedServers.eligible(config, now: at), isFalse);
  });
  test('Strict VPN and connected direct route never fall back to another route', () {
    expect(() => serviceRoutePort(ServiceRoute.vpn, false, 1, 2), throwsStateError);
    expect(serviceRoutePort(ServiceRoute.direct, false, 1, 2), isNull);
    expect(serviceRoutePort(ServiceRoute.direct, true, 1234, 5678), 1234);
    expect(serviceRoutePort(ServiceRoute.vpn, true, 1234, 5678), 5678);
    expect(() => serviceRoutePort(ServiceRoute.vpn, true, 1234, 0), throwsStateError);
  });
  test('HTTP errors remain distinct from successful responses and unsafe URLs are rejected', () {
    expect(ServiceResult.response(ServiceRoute.vpn, 204, 12).status, ServiceStatus.success);
    expect(ServiceResult.response(ServiceRoute.vpn, 405, 12).status, ServiceStatus.httpError);
    expect(ServiceResult.response(ServiceRoute.vpn, 403, 12).httpStatus, 403);
    expect(() => ServiceTarget.parseUrl('file:///private'), throwsFormatException);
    expect(() => ServiceTarget.parseUrl('https://user:pass@example.test/'), throwsFormatException);
  });
  test('Offline VPN starts no HTTP requests', () async {
    var created = 0;
    final checks = ServiceChecks(transportFactory: () { created++; return FakeTransport(); });
    await checks.run(ServiceTarget.defaults, ServiceRoute.vpn, connected: false, directPort: 1, vpnPort: 2);
    expect(created, 0);
    expect(checks.results.values.every((result) => result.errorCode == 'vpn_offline'), isTrue);
    checks.dispose();
  });
  test('Cancel closes in-flight requests and prevents queued requests or stale results', () async {
    final transports = <FakeTransport>[];
    final checks = ServiceChecks(transportFactory: () { final value = FakeTransport(); transports.add(value); return value; });
    final run = checks.run(ServiceTarget.defaults, ServiceRoute.vpn, connected: true, directPort: 1234, vpnPort: 5678);
    await Future<void>.delayed(Duration.zero);
    expect(transports.length, 3);
    expect(transports.every((transport) => transport.port == 5678), isTrue);
    checks.cancel();
    expect(transports.every((transport) => transport.closed), isTrue);
    for (final transport in transports) { transport.completer.complete(ServiceResult.response(ServiceRoute.vpn, 200, 10)); }
    await run;
    expect(transports.length, 3);
    expect(checks.results.values.every((result) => result.status == ServiceStatus.cancelled), isTrue);
    checks.dispose();
  });

  for (final width in [320.0, 360.0, 412.0]) {
    for (final scale in [1.0, 1.5]) {
      testWidgets('Compact Android layout $width dp / font $scale', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 1700);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final numbers = List.generate(4, (i) => ValueNotifier(i < 2 ? '↑ 999.99 GB' : '↓ 999.99 MB/s'));
        addTearDown(() { for (final number in numbers) { number.dispose(); } });
        var powerTaps = 0;
        SettingManager.getConfig().ui.antinetChecksExpanded = true;
        SettingManager.getConfig().ui.antinetServerExpanded = true;
        Future<void> noop() async {}
        await tester.pumpWidget(MaterialApp(locale: const Locale('ru'),
          supportedLocales: const [Locale('ru')], localizationsDelegates: GlobalMaterialLocalizations.delegates,
          builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
          home: Scaffold(body: SafeArea(child: AntinetCompactHome(
            connected: false, busy: false, pinned: false, canPin: false, canSwap: false, checkingServers: false,
            serverName: 'Очень длинное название выбранного сервера для проверки переноса',
            sourceName: 'Подписка с длинным названием', serverDetails: 'trojan · 123 ms',
            checkedCount: 15, favoritesCount: 24, directPort: 1234, vpnPort: 5678,
            uploadTotal: numbers[0], downloadTotal: numbers[1], uploadRate: numbers[2], downloadRate: numbers[3],
            onPower: () async { powerTaps++; }, onSelectServer: noop, onPin: noop, onSwap: noop,
            onCheckServers: noop, onCollect: noop, onSettings: () {}, onProfiles: () {}, onOriginal: () {},
          )))));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('ChatGPT'), findsOneWidget);
        expect(find.text('Instagram'), findsNothing);
        await tester.tap(find.byTooltip('Подключить'));
        await tester.pump();
        expect(powerTaps, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
  testWidgets('Leaving the home screen and backgrounding cancel active checks', (tester) async {
    final transports = <FakeTransport>[];
    final checks = ServiceChecks(transportFactory: () {
      final value = FakeTransport(); transports.add(value); return value;
    });
    final numbers = List.generate(4, (_) => ValueNotifier('0 B'));
    Future<void> noop() async {}
    var settingsOpened = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: AntinetCompactHome(
      checks: checks, connected: true, busy: false, pinned: false,
      canPin: false, canSwap: false, checkingServers: false,
      serverName: 'Fixture', sourceName: 'Source', serverDetails: '',
      checkedCount: 0, favoritesCount: 0, directPort: 1234, vpnPort: 5678,
      uploadTotal: numbers[0], downloadTotal: numbers[1], uploadRate: numbers[2], downloadRate: numbers[3],
      onPower: noop, onSelectServer: noop, onPin: noop, onSwap: noop,
      onCheckServers: noop, onCollect: noop, onSettings: () { settingsOpened++; },
      onProfiles: () {}, onOriginal: () {},
    ))));
    final first = checks.run(ServiceTarget.defaults, ServiceRoute.vpn,
      connected: true, directPort: 1234, vpnPort: 5678);
    await tester.pump();
    await tester.tap(find.byTooltip('Settings'));
    expect(settingsOpened, 1);
    expect(transports.every((transport) => transport.closed), isTrue);
    for (final transport in transports) { transport.completer.complete(ServiceResult.response(ServiceRoute.vpn, 200, 1)); }
    await first;
    final second = checks.run(ServiceTarget.defaults, ServiceRoute.vpn,
      connected: true, directPort: 1234, vpnPort: 5678);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(transports.every((transport) => transport.closed), isTrue);
    for (final transport in transports.where((transport) => !transport.completer.isCompleted)) {
      transport.completer.complete(ServiceResult.response(ServiceRoute.vpn, 200, 1));
    }
    await second;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox());
    checks.dispose();
    for (final number in numbers) { number.dispose(); }
  });
}
