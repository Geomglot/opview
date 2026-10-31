// recognizing a comma on the network: real sockets, so no Flutter test binding (it fakes HttpClient)

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opview/services/impl/subnet_scan_discovery.dart';

void main() {
  test('a comma is recognized by its answer, not just an open port', () async {
    final comma = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    comma.listen((r) {
      r.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'carState': {}}))
        ..close();
    });
    final nas = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    nas.listen((r) {
      r.response
        ..statusCode = 404
        ..close();
    });
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final closedPort = closed.port;
    await closed.close();

    expect(await isComma('127.0.0.1', port: comma.port), isTrue);
    expect(await isComma('127.0.0.1', port: nas.port), isFalse);
    expect(await isComma('127.0.0.1', port: closedPort), isFalse);
    await comma.close(force: true);
    await nas.close(force: true);
  });

}
