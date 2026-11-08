import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

enum ServiceRoute { direct, vpn }
enum ServiceStatus { idle, running, success, httpError, error, cancelled }

class ServiceTarget {
  final String id;
  final String label;
  final String url;
  const ServiceTarget(this.id, this.label, this.url);
  static const defaults = [
    ServiceTarget('google', 'Google', 'https://www.google.com/generate_204'),
    ServiceTarget('telegram', 'Telegram', 'https://telegram.org/'),
    ServiceTarget('youtube', 'YouTube', 'https://www.youtube.com/generate_204'),
    ServiceTarget('steam', 'Steam', 'https://store.steampowered.com/'),
    ServiceTarget('discord', 'Discord', 'https://discord.com/'),
    ServiceTarget('chatgpt', 'ChatGPT', 'https://chatgpt.com/'),
  ];

  static Uri parseUrl(String text) {
    final uri = Uri.tryParse(text.trim());
    if (text.length > 2048 || uri == null ||
        !['http', 'https'].contains(uri.scheme) || uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('Enter an HTTP or HTTPS address without credentials.');
    }
    return uri;
  }
}

class ServiceResult {
  final ServiceStatus status;
  final ServiceRoute route;
  final int milliseconds;
  final int? httpStatus;
  final String errorCode;
  final String detail;
  const ServiceResult(this.status, this.route,
      {this.milliseconds = 0, this.httpStatus, this.errorCode = '', this.detail = ''});
  factory ServiceResult.response(ServiceRoute route, int status, int elapsed) =>
      ServiceResult(status >= 200 && status < 400 ? ServiceStatus.success : ServiceStatus.httpError,
          route, milliseconds: elapsed, httpStatus: status);
}

/// A missing VPN is an error, never an implicit direct connection.
int? serviceRoutePort(ServiceRoute route, bool connected, int directPort, int vpnPort) {
  if (route == ServiceRoute.vpn && !connected) throw StateError('vpn_offline');
  if (!connected) return null;
  final port = route == ServiceRoute.vpn ? vpnPort : directPort;
  if (port < 1 || port > 65535) throw StateError('route_unavailable');
  return port;
}

abstract interface class ServiceTransport {
  Future<ServiceResult> head(Uri uri, ServiceRoute route, int? port, Duration timeout);
  void close();
}

class HttpServiceTransport implements ServiceTransport {
  final HttpClient _client = HttpClient();
  @override
  Future<ServiceResult> head(Uri uri, ServiceRoute route, int? port, Duration timeout) async {
    final watch = Stopwatch()..start();
    _client.connectionTimeout = timeout;
    _client.userAgent = 'AntiNet-K/1.2.25';
    _client.findProxy = (_) => port == null ? 'DIRECT' : 'PROXY 127.0.0.1:$port';
    try {
      final response = await (() async {
        final request = await _client.openUrl('HEAD', uri);
        request.followRedirects = true;
        request.maxRedirects = 3;
        final response = await request.close();
        await response.drain<void>();
        return response;
      })().timeout(timeout);
      return ServiceResult.response(route, response.statusCode, watch.elapsedMilliseconds);
    } on TimeoutException {
      return ServiceResult(ServiceStatus.error, route,
          milliseconds: watch.elapsedMilliseconds, errorCode: 'timeout');
    } on HandshakeException catch (error) {
      return ServiceResult(ServiceStatus.error, route,
          milliseconds: watch.elapsedMilliseconds, errorCode: 'tls', detail: error.toString());
    } catch (error) {
      return ServiceResult(ServiceStatus.error, route,
          milliseconds: watch.elapsedMilliseconds, errorCode: 'network', detail: error.toString());
    } finally { close(); }
  }
  @override
  void close() => _client.close(force: true);
}

class ServiceChecks extends ChangeNotifier {
  final ServiceTransport Function() transportFactory;
  final Map<String, ServiceResult> results = {};
  final Set<ServiceTransport> _active = {};
  bool _disposed = false;
  bool running = false;
  int _generation = 0;
  ServiceChecks({ServiceTransport Function()? transportFactory})
      : transportFactory = transportFactory ?? HttpServiceTransport.new;

  void _notify() { if (!_disposed) notifyListeners(); }

  void cancel() {
    _generation++;
    for (final transport in _active.toList()) { transport.close(); }
    _active.clear();
    for (final entry in results.entries.toList()) {
      if (entry.value.status == ServiceStatus.running) {
        results[entry.key] = ServiceResult(ServiceStatus.cancelled, entry.value.route);
      }
    }
    running = false;
    _notify();
  }

  void reset() { cancel(); results.clear(); _notify(); }

  Future<void> run(List<ServiceTarget> targets, ServiceRoute route, {
    required bool connected, required int directPort, required int vpnPort,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (_disposed) return;
    cancel();
    final generation = _generation;
    int? port;
    try { port = serviceRoutePort(route, connected, directPort, vpnPort); }
    on StateError catch (error) {
      for (final target in targets) {
        results[target.id] = ServiceResult(ServiceStatus.error, route,
            errorCode: error.message.toString());
      }
      _notify();
      return;
    }
    running = true;
    for (final target in targets) { results[target.id] = ServiceResult(ServiceStatus.running, route); }
    _notify();
    int next = 0;
    Future<void> worker() async {
      while (!_disposed && generation == _generation && next < targets.length) {
        final target = targets[next++];
        ServiceTransport? transport;
        ServiceResult result;
        try {
          final uri = ServiceTarget.parseUrl(target.url);
          transport = transportFactory();
          _active.add(transport);
          result = await transport.head(uri, route, port, timeout);
        } catch (error) {
          result = ServiceResult(ServiceStatus.error, route,
              errorCode: 'address', detail: error.toString());
        } finally {
          if (transport != null) { transport.close(); _active.remove(transport); }
        }
        if (_disposed || generation != _generation) return;
        results[target.id] = result;
        _notify();
      }
    }
    await Future.wait(List.generate(targets.length.clamp(0, 3), (_) => worker()));
    if (!_disposed && generation == _generation) { running = false; _notify(); }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    cancel();
    super.dispose();
  }
}
