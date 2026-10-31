// Subnet scan discovery
// Finds the comma by asking every address on the phone's own network, for when mDNS finds nothing.
// The Rivian hotspot gives the comma a new address on each drive, but the phone and the comma
// always share the first three numbers, so the 254 addresses beside the phone's own are enough.
// The Rivian allows only 8 devices and hands out the low numbers, so the scan counts up from 1.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:opview/services/discovery.dart';

const _port = 5001;            // webrtcd
const _connectTimeout = Duration(milliseconds: 400);
const _askTimeout = Duration(seconds: 2);
const _parallel = 32;           // addresses probed at once

/// interface names that are mobile data, VPNs or loopback, never the network the comma is on
final _notWifi = RegExp(r'^(rmnet|ccmni|pdp|v4-rmnet|tun|ppp|lo|dummy|ip6tnl|sit)');

/// the first three numbers of each IPv4 network the phone is on, Wi-Fi and hotspot first
Future<List<String>> localPrefixes() async {
  final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
  return prefixesOf([
    for (final iface in interfaces)
      for (final addr in iface.addresses) (iface.name, addr.address),
  ]);
}

/// [localPrefixes] for a list of (interface name, address) pairs
List<String> prefixesOf(List<(String, String)> addresses) {
  final prefixes = <String>[];
  for (final (name, address) in addresses) {
    if (_notWifi.hasMatch(name)) continue;
    final parts = address.split('.');
    if (parts.length != 4 || address.startsWith('127.') || address.startsWith('169.254.')) continue;
    final prefix = parts.take(3).join('.');
    if (!prefixes.contains(prefix)) prefixes.add(prefix);
  }
  return prefixes;
}

/// every address on [prefix], counting up from 1
List<String> candidates(String prefix) => [for (var i = 1; i <= 254; i++) '$prefix.$i'];

/// true if [host] is a comma: webrtcd answers a schema request with that service in it.
/// Other things listen on 5001 too (some home NAS boxes), so an open port alone is not enough
Future<bool> isComma(String host, {int port = _port, http.Client? client}) async {
  try {
    final socket = await Socket.connect(host, port, timeout: _connectTimeout);
    socket.destroy();
  } catch (_) {
    return false;
  }
  final c = client ?? http.Client();
  try {
    final response =
        await c.get(Uri.parse('http://$host:$port/schema?services=carState')).timeout(_askTimeout);
    if (response.statusCode != 200) return false;
    final body = jsonDecode(response.body);
    return body is Map && body.containsKey('carState');
  } catch (_) {
    return false;
  } finally {
    if (client == null) c.close();
  }
}

class SubnetScanDiscovery implements Discovery {
  final Future<List<String>> Function() prefixes;
  final Future<bool> Function(String host) probe;

  SubnetScanDiscovery({
    Future<List<String>> Function()? prefixes,
    Future<bool> Function(String host)? probe,
  })  : prefixes = prefixes ?? localPrefixes,
        probe = probe ?? isComma;

  final _devicesController = StreamController<DiscoveredDevice>.broadcast();
  int _run = 0;  // a new start or a stop ends the scan in progress

  @override
  Stream<DiscoveredDevice> get devices => _devicesController.stream;

  @override
  Future<void> start() async {
    final run = ++_run;
    unawaited(_scan(run));
  }

  Future<void> _scan(int run) async {
    try {
      for (final prefix in await prefixes()) {
        final queue = candidates(prefix);
        debugPrint('[opview] scanning $prefix.x for the comma');
        String? found;
        Future<void> worker() async {
          while (queue.isNotEmpty && found == null && run == _run) {
            final host = queue.removeAt(0);
            if (await probe(host) && found == null && run == _run) found = host;
          }
        }
        await Future.wait([for (var i = 0; i < _parallel; i++) worker()]);
        if (run != _run) return;
        if (found != null) {
          _devicesController.add(DiscoveredDevice(host: found!, displayName: 'comma'));
          return;
        }
      }
      debugPrint('[opview] scan found no comma');
    } catch (e) {
      debugPrint('[opview] scan failed: $e');
    }
  }

  @override
  Future<void> stop() async {
    _run++;
  }

  @override
  void dispose() {
    _run++;
    _devicesController.close();
  }
}

/// several ways of finding the comma at once; whichever finds it first wins
class MultiDiscovery implements Discovery {
  final List<Discovery> parts;
  final _devicesController = StreamController<DiscoveredDevice>.broadcast();
  final List<StreamSubscription> _subs = [];

  MultiDiscovery(this.parts) {
    for (final p in parts) {
      _subs.add(p.devices.listen(_devicesController.add));
    }
  }

  @override
  Stream<DiscoveredDevice> get devices => _devicesController.stream;

  @override
  Future<void> start() async {
    await Future.wait([for (final p in parts) p.start()]);
  }

  @override
  Future<void> stop() async {
    await Future.wait([for (final p in parts) p.stop()]);
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    for (final p in parts) {
      p.dispose();
    }
    _devicesController.close();
  }
}
