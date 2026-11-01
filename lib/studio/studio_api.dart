// Talks to the local replay server (replay/oprivview_replay/server.py)

import 'dart:convert';
import 'dart:io';

class StudioError implements Exception {
  final String message;
  StudioError(this.message);
  @override
  String toString() => message;
}

class ParamSpec {
  final String name, label, help, kind;
  final Object? defaultValue;
  final List<String>? choices;
  final bool many;
  ParamSpec(Map<String, dynamic> j)
      : name = j['name'],
        label = j['label'],
        help = j['help'],
        kind = j['kind'],
        defaultValue = j['default'],
        choices = (j['choices'] as List?)?.cast<String>(),
        many = j['many'] as bool;
}

class RouteInfo {
  final String route;
  final int first, last;
  RouteInfo(Map<String, dynamic> j)
      : route = j['route'],
        first = j['first'],
        last = j['last'];
}

class RangeRequest {
  final String route;
  final int? startSegment, endSegment;
  final String? startTime, endTime;
  RangeRequest(this.route, {this.startSegment, this.endSegment, this.startTime, this.endTime});
  Map<String, dynamic> toJson() => {
        'route': route,
        'start_segment': startSegment,
        'end_segment': endSegment,
        'start_time': startTime,
        'end_time': endTime,
      };
}

class StudioApi {
  final Uri base;
  StudioApi(this.base);
  final _client = HttpClient()..connectionTimeout = const Duration(seconds: 5);

  Future<dynamic> _call(String method, String path, [Object? body]) async {
    final req = await _client.openUrl(method, base.resolve(path));
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode >= 400) {
      String detail = text;
      try {
        detail = (jsonDecode(text) as Map)['detail'].toString();
      } catch (_) {}
      throw StudioError(detail);
    }
    return jsonDecode(text);
  }

  Future<bool> healthy() async {
    try {
      await _call('GET', '/health');
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<List<ParamSpec>> params() async => [for (final j in await _call('GET', '/params')) ParamSpec(j)];

  /// null when the comma cannot be reached; [error] says why
  Future<({List<RouteInfo>? routes, String? error})> routes() async {
    final j = await _call('GET', '/routes');
    if (j['online'] != true) return (routes: null, error: j['error'] as String?);
    return (routes: [for (final r in j['routes']) RouteInfo(r)], error: null);
  }

  Future<Map<String, dynamic>> resolve(RangeRequest r) async => await _call('POST', '/resolve', r.toJson());

  Future<Map<String, dynamic>> startJob(RangeRequest r, Map<String, Object?> options, String? output) async =>
      await _call('POST', '/jobs', {...r.toJson(), 'options': options, 'output': output});

  Future<Map<String, dynamic>> job(String id) async => await _call('GET', '/jobs/$id');

  void close() => _client.close(force: true);
}
