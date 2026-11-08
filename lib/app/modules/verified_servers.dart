import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:karing/app/utils/proxy_conf_utils.dart';

class ServerCheckTicket {
  final String key;
  final String fingerprint;
  final int serial;
  const ServerCheckTicket(this.key, this.fingerprint, this.serial);
}

/// Only completed, current-session native checks qualify a server for bulk
/// collection. Imported latency strings and cached history are not verdicts.
abstract final class VerifiedServers {
  static const maximumFavorites = 1000;
  static const maxAge = Duration(hours: 1);
  static int _serial = 0;
  static final Map<String, int> _latest = {};
  static final Map<String, ({String fingerprint, DateTime at})> _passed = {};

  static String key(ProxyConfig config) => jsonEncode([config.groupid, config.tag]);

  static dynamic _canonical(dynamic value) {
    if (value is Map) {
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      return {for (final key in keys) key: _canonical(value[key])};
    }
    if (value is List) return value.map(_canonical).toList();
    return value;
  }

  static String fingerprint(ProxyConfig config) {
    final data = jsonDecode(jsonEncode(config.toJson())) as Map<String, dynamic>;
    for (final field in ['groupid', 'tag', 'latency', 'attach', 'outlet_ip', 'outlet_region']) {
      data.remove(field);
    }
    data['type'] = config.type;
    data['server'] = config.server;
    data['server_port'] = config.serverport;
    return sha256.convert(utf8.encode(jsonEncode(_canonical(data)))).toString();
  }

  static ServerCheckTicket begin(ProxyConfig config) {
    final id = key(config);
    final ticket = ServerCheckTicket(id, fingerprint(config), ++_serial);
    _latest[id] = ticket.serial;
    _passed.remove(id);
    // Checking a large source should not leave unbounded historical verdicts.
    if (_latest.length > 20000) {
      final oldest = _latest.keys.first;
      _latest.remove(oldest);
      _passed.remove(oldest);
    }
    return ticket;
  }

  static void complete(ServerCheckTicket ticket, ProxyConfig config,
      {required bool success, DateTime? now}) {
    if (_latest[ticket.key] != ticket.serial || key(config) != ticket.key) return;
    _passed.remove(ticket.key);
    if (success && fingerprint(config) == ticket.fingerprint) {
      _passed[ticket.key] = (fingerprint: ticket.fingerprint, at: now ?? DateTime.now());
    }
  }

  static bool eligible(ProxyConfig config, {DateTime? now}) {
    final verdict = _passed[key(config)];
    if (verdict == null || fingerprint(config) != verdict.fingerprint) return false;
    final age = (now ?? DateTime.now()).difference(verdict.at);
    return !age.isNegative && age <= maxAge;
  }

  /// Append original native references, preserving existing manual favorites,
  /// their order, source IDs and all connection parameters.
  static List<ProxyConfig> collect(Iterable<ProxyConfig> candidates,
      List<ProxyConfig> favorites, {Set<String> disabled = const {}}) {
    final seen = favorites.map(fingerprint).toSet();
    final added = <ProxyConfig>[];
    for (final config in candidates) {
      if (favorites.length >= maximumFavorites) break;
      if (disabled.contains(key(config)) || !eligible(config)) continue;
      if (!seen.add(fingerprint(config))) continue;
      favorites.add(config);
      added.add(config);
    }
    return added;
  }

  static void reset() { _latest.clear(); _passed.clear(); _serial++; }
}
