import 'dart:async';
import 'dart:ui' show FontFeature;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:karing/app/modules/service_checks.dart';
import 'package:karing/app/modules/setting_manager.dart';

class AntinetCompactHome extends StatefulWidget {
  final bool connected, busy, pinned, canPin, canSwap, checkingServers;
  final String serverName, sourceName, serverDetails;
  final int checkedCount, favoritesCount, directPort, vpnPort;
  final ValueListenable<String> uploadTotal, downloadTotal, uploadRate, downloadRate;
  final Future<void> Function() onPower, onSelectServer, onPin, onSwap,
      onCheckServers, onCollect;
  final VoidCallback onSettings, onProfiles, onOriginal;
  final ServiceChecks? checks;
  const AntinetCompactHome({super.key,
    required this.connected, required this.busy, required this.pinned,
    required this.canPin, required this.canSwap, required this.checkingServers,
    required this.serverName, required this.sourceName, required this.serverDetails,
    required this.checkedCount, required this.favoritesCount,
    required this.directPort, required this.vpnPort,
    required this.uploadTotal, required this.downloadTotal,
    required this.uploadRate, required this.downloadRate,
    required this.onPower, required this.onSelectServer, required this.onPin,
    required this.onSwap, required this.onCheckServers, required this.onCollect,
    required this.onSettings, required this.onProfiles, required this.onOriginal,
    this.checks,
  });
  @override
  State<AntinetCompactHome> createState() => _AntinetCompactHomeState();
}

class _AntinetCompactHomeState extends State<AntinetCompactHome> with WidgetsBindingObserver {
  late final ServiceChecks _checks = widget.checks ?? ServiceChecks();
  late ServiceRoute _route = widget.connected ? ServiceRoute.vpn : ServiceRoute.direct;
  String text(String ru, String en) => Localizations.localeOf(context).languageCode == 'ru' ? ru : en;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checks.addListener(_changed);
  }
  void _changed() { if (mounted) setState(() {}); }
  @override
  void didUpdateWidget(AntinetCompactHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.connected != widget.connected || oldWidget.serverName != widget.serverName) {
      _checks.reset();
    } else if (!oldWidget.busy && widget.busy) {
      _checks.cancel();
    }
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _checks.cancel();
  }
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _checks.removeListener(_changed);
    if (widget.checks == null) { _checks.dispose(); } else { _checks.cancel(); }
    super.dispose();
  }

  List<ServiceTarget> get _targets => ServiceTarget.defaults.map((target) =>
    ServiceTarget(target.id, target.label,
      SettingManager.getConfig().ui.antinetServiceUrls[target.id] ?? target.url)).toList();

  Future<void> _run() => _checks.run(_targets, _route,
      connected: widget.connected, directPort: widget.directPort, vpnPort: widget.vpnPort);

  Widget _number(ValueListenable<String> value) => ValueListenableBuilder<String>(
    valueListenable: value,
    builder: (_, value, _) => Text(value, textAlign: TextAlign.right,
      style: const TextStyle(fontSize: 12, fontFeatures: [FontFeature.tabularFigures()])),
  );

  Widget _card(String title, IconData icon, Widget body, {
    bool? expanded, VoidCallback? onToggle, Widget? action,
  }) => Card(
    margin: const EdgeInsets.only(bottom: 10),
    clipBehavior: Clip.antiAlias,
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      InkWell(onTap: onToggle, child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        child: Row(children: [
          Icon(icon, size: 19), const SizedBox(width: 8),
          Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600))),
          if (action != null) action,
          if (expanded != null) IconButton(
            tooltip: expanded ? text('Свернуть', 'Collapse') : text('Развернуть', 'Expand'),
            onPressed: onToggle,
            icon: Icon(expanded ? Icons.expand_less : Icons.expand_more),
          ),
        ]),
      )),
      if (expanded != false) Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 12), child: body),
    ]),
  );

  String _resultLabel(ServiceResult? result) {
    if (result == null || result.status == ServiceStatus.idle) return text('Не проверяли', 'Not checked');
    switch (result.status) {
      case ServiceStatus.running: return text('Проверка…', 'Checking…');
      case ServiceStatus.success: return '${result.milliseconds} ${text('мс', 'ms')}';
      case ServiceStatus.httpError: return 'HTTP ${result.httpStatus}';
      case ServiceStatus.cancelled: return text('Остановлено', 'Stopped');
      case ServiceStatus.error:
        return switch (result.errorCode) {
          'vpn_offline' => text('VPN отключён', 'VPN is off'),
          'route_unavailable' => text('Маршрут недоступен', 'Route unavailable'),
          'timeout' => text('Нет ответа', 'Timed out'),
          'tls' => text('Ошибка TLS', 'TLS error'),
          'address' => text('Проверьте адрес', 'Check address'),
          _ => text('Ошибка сети', 'Network error'),
        };
      case ServiceStatus.idle: return text('Не проверяли', 'Not checked');
    }
  }

  Future<void> _details(ServiceTarget target, ServiceResult? result) async {
    _checks.cancel();
    result = _checks.results[target.id] ?? result;
    await showDialog<void>(context: context, builder: (context) => AlertDialog(
      title: Text(target.label),
      content: SelectableText([
        target.url,
        if (result != null) result.route == ServiceRoute.vpn ? text('Через VPN', 'Through VPN') : text('Напрямую', 'Direct'),
        _resultLabel(result),
        if (result?.httpStatus != null) 'HTTP ${result!.httpStatus}',
        if (result?.httpStatus == 405) text('Сервер не разрешает проверку методом HEAD.', 'The server does not allow HEAD requests.'),
        if (result?.detail.isNotEmpty ?? false) result!.detail,
      ].join('\n\n')),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(text('Закрыть', 'Close')))],
    ));
  }

  Future<void> _edit(ServiceTarget target) async {
    _checks.cancel();
    final input = TextEditingController(text: target.url);
    String? error;
    final url = await showDialog<String>(context: context, builder: (context) =>
      StatefulBuilder(builder: (context, update) => AlertDialog(
        title: Text('${target.label} · ${text('адрес проверки', 'check URL')}'),
        content: TextField(controller: input, maxLength: 2048,
          keyboardType: TextInputType.url, maxLines: 3,
          decoration: InputDecoration(errorText: error, hintText: 'https://...')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(text('Отмена', 'Cancel'))),
          TextButton(onPressed: () {
            try { ServiceTarget.parseUrl(input.text); Navigator.pop(context, input.text.trim()); }
            catch (_) { update(() => error = text('Нужен адрес HTTP или HTTPS', 'Enter an HTTP or HTTPS URL')); }
          }, child: Text(text('Сохранить', 'Save'))),
        ],
      )));
    input.dispose();
    if (url == null || !mounted) return;
    SettingManager.getConfig().ui.antinetServiceUrls[target.id] = url;
    await SettingManager.save();
    _checks.reset();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ui = SettingManager.getConfig().ui;
    final status = widget.connected ? text('Подключено', 'Connected') :
      widget.busy ? text('Подождите…', 'Please wait…') : text('Отключено', 'Disconnected');
    return Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(12, 4, 4, 0), child: Row(children: [
        const Expanded(child: Text('AntiNet K', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600))),
        IconButton(tooltip: text('Подписки', 'Profiles'), onPressed: () { _checks.cancel(); widget.onProfiles(); }, icon: const Icon(Icons.folder_outlined)),
        IconButton(tooltip: text('Обычный экран Karing', 'Original Karing layout'), onPressed: () { _checks.cancel(); widget.onOriginal(); }, icon: const Icon(Icons.dashboard_outlined)),
        IconButton(tooltip: text('Настройки', 'Settings'), onPressed: () { _checks.cancel(); widget.onSettings(); }, icon: const Icon(Icons.settings_outlined)),
      ])),
      Expanded(child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(10, 4, 10, 12), child: Column(children: [
        Card(margin: const EdgeInsets.only(bottom: 10), child: Padding(
          padding: const EdgeInsets.all(12), child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Expanded(flex: 6, child: Row(children: [
              IconButton.filled(
                tooltip: widget.connected ? text('Отключить', 'Disconnect') : text('Подключить', 'Connect'),
                onPressed: widget.busy ? null : () => unawaited(widget.onPower()),
                icon: widget.busy ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)) :
                  Icon(widget.connected ? Icons.stop_rounded : Icons.power_settings_new),
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(status, style: const TextStyle(fontWeight: FontWeight.w600))),
            ])),
            const SizedBox(width: 8),
            Expanded(flex: 5, child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                _number(widget.uploadTotal), _number(widget.uploadRate),
              ])),
              const SizedBox(width: 6),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                _number(widget.downloadTotal), _number(widget.downloadRate),
              ])),
            ])),
          ]),
        )),
        _card(text('Сервер', 'Server'), Icons.dns_outlined,
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            InkWell(onTap: widget.busy ? null : () { _checks.cancel(); unawaited(widget.onSelectServer()); },
              child: Padding(padding: const EdgeInsets.symmetric(vertical: 7), child: Text(widget.serverName,
                style: const TextStyle(fontWeight: FontWeight.w600)))),
            if (widget.sourceName.isNotEmpty) Text(widget.sourceName, style: theme.textTheme.bodySmall),
            if (widget.serverDetails.isNotEmpty) Text(widget.serverDetails, style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 4, children: [
              OutlinedButton.icon(onPressed: widget.busy || widget.checkingServers ? null : () => unawaited(widget.onCheckServers()),
                icon: widget.checkingServers ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.play_arrow, size: 18),
                label: Text(text('Проверить серверы', 'Check servers'))),
              OutlinedButton.icon(onPressed: widget.busy || widget.checkingServers ? null : () => unawaited(widget.onCollect()),
                icon: const Icon(Icons.star_border, size: 18), label: Text(text('Собрать рабочие', 'Collect working'))),
            ]),
            Text('${text('Проверенных', 'Verified')}: ${widget.checkedCount} · ${text('Избранное', 'Favorites')}: ${widget.favoritesCount}',
              style: theme.textTheme.bodySmall),
          ]), expanded: ui.antinetServerExpanded,
          onToggle: () { ui.antinetServerExpanded = !ui.antinetServerExpanded; unawaited(SettingManager.save()); setState(() {}); },
          action: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(tooltip: widget.pinned ? text('Вернуть автовыбор', 'Return to auto select') : text('Закрепить текущий сервер', 'Pin current server'),
              onPressed: widget.busy || !widget.canPin ? null : () => unawaited(widget.onPin()),
              icon: Icon(widget.pinned ? Icons.lock : Icons.lock_open)),
            IconButton(tooltip: text('Следующий проверенный сервер', 'Next verified server'),
              onPressed: widget.busy || !widget.canSwap ? null : () => unawaited(widget.onSwap()),
              icon: const Icon(Icons.swap_horiz)),
          ]),
        ),
        _card(text('Доступность сервисов', 'Service reachability'), Icons.network_check,
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Wrap(spacing: 8, children: [
              for (final route in ServiceRoute.values) ChoiceChip(
                label: Text(route == ServiceRoute.vpn ? text('Через VPN', 'Through VPN') : text('Напрямую', 'Direct')),
                selected: _route == route,
                onSelected: (_) { _checks.reset(); setState(() => _route = route); },
              ),
            ]),
            const SizedBox(height: 8),
            LayoutBuilder(builder: (context, box) {
              final columns = box.maxWidth >= 550 ? 3 : 2;
              final width = (box.maxWidth - (columns - 1) * 8) / columns;
              return Wrap(spacing: 8, runSpacing: 8, children: [
                for (final target in _targets) SizedBox(width: width, child: Material(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(borderRadius: BorderRadius.circular(10),
                    onTap: () => unawaited(_details(target, _checks.results[target.id])),
                    onLongPress: () => unawaited(_edit(target)),
                    child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 68), child: Padding(
                      padding: const EdgeInsets.all(9), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(target.label, style: const TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        Text(_resultLabel(_checks.results[target.id]), style: TextStyle(
                          color: _checks.results[target.id]?.status == ServiceStatus.success ? Colors.green.shade700 :
                            _checks.results[target.id]?.status == ServiceStatus.httpError || _checks.results[target.id]?.status == ServiceStatus.error ? theme.colorScheme.error : null,
                        )),
                      ]),
                    )),
                  ),
                )),
              ]);
            }),
            const SizedBox(height: 8),
            Text(text('Проверяет ответ адресов. Удерживайте сервис, чтобы изменить адрес.',
              'Checks URL responses. Hold a service to change its URL.'), style: theme.textTheme.bodySmall),
          ]), expanded: ui.antinetChecksExpanded,
          onToggle: () { ui.antinetChecksExpanded = !ui.antinetChecksExpanded; if (!ui.antinetChecksExpanded) _checks.cancel(); unawaited(SettingManager.save()); setState(() {}); },
          action: IconButton(tooltip: _checks.running ? text('Остановить проверку', 'Stop checks') : text('Проверить сервисы', 'Check services'),
            onPressed: widget.busy ? null : () { if (_checks.running) { _checks.cancel(); } else { unawaited(_run()); } },
            icon: Icon(_checks.running ? Icons.stop_circle_outlined : Icons.refresh)),
        ),
      ]))),
    ]);
  }
}
