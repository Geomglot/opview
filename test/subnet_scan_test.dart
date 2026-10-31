// finding the comma when mDNS does not: the scan of the phone's own network, and switching to a
// found address without waiting for an old one to time out

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/connection_manager.dart';
import 'package:opview/services/discovery.dart';
import 'package:opview/services/impl/subnet_scan_discovery.dart';
import 'package:opview/services/transport.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeDiscovery implements Discovery {
  final controller = StreamController<DiscoveredDevice>.broadcast();
  final started = Completer<void>();  // the app is listening once this completes
  @override
  Stream<DiscoveredDevice> get devices => controller.stream;
  @override
  Future<void> start() async {
    if (!started.isCompleted) started.complete();
  }
  @override
  Future<void> stop() async {}
  @override
  void dispose() => controller.close();
}

/// connects to [answers] at once and leaves every other address hanging, like a comma that moved
class _FakeTransport implements Transport {
  final Set<String> answers;
  final tried = <String>[];
  _FakeTransport(this.answers);
  @override
  Stream<String> get dataStream => const Stream.empty();
  @override
  Stream<TransportState> get stateStream => const Stream.empty();
  @override
  dynamic get videoRenderer => null;
  @override
  Future<void> connect(String host, {String camera = 'road'}) {
    tried.add(host);
    return answers.contains(host) ? Future.value() : Completer<void>().future;
  }
  @override
  Future<void> close() async {}
  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the phone\'s networks', () {
    test('Wi-Fi and hotspot count; mobile data, VPN, loopback and self-assigned do not', () {
      expect(
          prefixesOf([
            ('rmnet_data0', '10.45.12.9'),
            ('wlan0', '192.168.37.12'),
            ('tun0', '10.8.0.2'),
            ('lo', '127.0.0.1'),
            ('wlan1', '169.254.3.4'),
            ('swlan0', '192.168.43.1'),
            ('wlan0', '192.168.37.99'),
          ]),
          ['192.168.37', '192.168.43']);
    });

    test('every address once, counting up from 1, where the Rivian puts its few devices', () {
      final list = candidates('192.168.37');
      expect(list.take(3), ['192.168.37.1', '192.168.37.2', '192.168.37.3']);
      expect(list.last, '192.168.37.254');
      expect(list.toSet().length, 254);
    });
  });

  group('scan', () {
    test('finds the comma at its new address on the phone\'s network', () async {
      final probed = <String>[];
      final scan = SubnetScanDiscovery(
        prefixes: () async => ['192.168.37'],
        probe: (h) async {
          probed.add(h);
          return h == '192.168.37.6';
        },
      );
      final found = scan.devices.first;
      await scan.start();
      expect((await found).host, '192.168.37.6');
      expect(probed.first, '192.168.37.1');
      scan.dispose();
    });

    test('stopping ends the scan', () async {
      var probes = 0;
      final scan = SubnetScanDiscovery(
        prefixes: () async => ['192.168.37'],
        probe: (h) async {
          probes++;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return false;
        },
      );
      await scan.start();
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await scan.stop();
      final atStop = probes;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(probes, atStop);
      expect(probes, lessThan(254));
      scan.dispose();
    });

    test('two ways of searching at once: whichever finds the comma first is heard', () async {
      final a = _FakeDiscovery();
      final b = _FakeDiscovery();
      final both = MultiDiscovery([a, b]);
      final found = both.devices.first;
      b.controller.add(DiscoveredDevice(host: '192.168.37.140', displayName: 'comma'));
      expect((await found).host, '192.168.37.140');
      both.dispose();
    });
  });

  group('connecting', () {
    setUp(() {
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
      messenger.setMockMethodCallHandler(const MethodChannel('org.dragonpilot.opview/wake_lock'), (call) async => null);
    });

    test('a found address is used at once, not after the old one times out', () async {
      // the remembered address has to be on the machine's own network to be tried at all
      final local = (await NetworkInterface.list(type: InternetAddressType.IPv4))
          .expand((i) => i.addresses)
          .map((a) => a.address)
          .firstOrNull;
      if (local == null) {
        markTestSkipped('no network to test on');
        return;
      }
      final prefix = local.split('.').take(3).join('.');
      final oldHost = '$prefix.23';
      final newHost = '$prefix.140';
      SharedPreferences.setMockInitialValues({'last_known_host': oldHost});
      final discovery = _FakeDiscovery();
      final transport = _FakeTransport({newHost});
      final ui = UIState();
      final cm = ConnectionManager(ui, discovery: discovery, transport: transport);
      cm.start();
      await discovery.started.future;
      await pumpEventQueue();
      // the old address is being tried and will not answer
      expect(transport.tried, [oldHost]);

      discovery.controller.add(DiscoveredDevice(host: newHost, displayName: 'comma'));
      await pumpEventQueue();
      expect(transport.tried, [oldHost, newHost]);
      expect(cm.host, newHost);
      expect(ui.isConnected, isTrue);
    });

    test('a typed address on another network is passed over and the search runs instead', () async {
      SharedPreferences.setMockInitialValues({'manual_host': '203.0.113.7'});
      final discovery = _FakeDiscovery();
      final transport = _FakeTransport({'203.0.113.9'});
      final ui = UIState();
      final cm = ConnectionManager(ui, discovery: discovery, transport: transport);
      cm.start();
      await discovery.started.future;
      await pumpEventQueue();
      expect(transport.tried, isEmpty);

      discovery.controller.add(DiscoveredDevice(host: '203.0.113.9', displayName: 'comma'));
      await pumpEventQueue();
      expect(transport.tried, ['203.0.113.9']);
      expect(ui.isConnected, isTrue);
      // still saved, for when the phone is back on that network
      expect(await cm.loadManualHost(), '203.0.113.7');
    });
  });
}
