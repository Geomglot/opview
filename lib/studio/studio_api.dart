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
  final bool many, advanced;
  ParamSpec(Map<String, dynamic> j)
      : name = j['name'],
        label = j['label'],
        help = j['help'],
        kind = j['kind'],
        defaultValue = j['default'],
        choices = (j['choices'] as List?)?.cast<String>(),
        many = j['many'] as bool,
        advanced = j['advanced'] == true;
}

class RouteInfo {
  final String route;
  final int first, last;
  final bool onDevice, onConnect;
  final String? localStart;
  final double? km;
  /// 'full' when the comma or Connect has everything, 'logs' for the full log with the small video, 'quick' for the
  /// small files only, 'small' for a drive on Connect whose files have not been looked at yet
  final String detail;
  /// the towns it started and ended in, when they are known
  final String? place;
  /// set on someone else's public drive: what to give [StudioApi.removeDrive] to take it off the list
  final String? addedAs;
  RouteInfo(Map<String, dynamic> j)
      : route = j['route'],
        first = j['first'],
        last = j['last'],
        onDevice = j['on_device'] == true,
        onConnect = j['on_connect'] == true,
        localStart = j['local_start'] as String?,
        km = (j['km'] as num?)?.toDouble(),
        detail = j['detail'] as String? ?? 'full',
        place = j['place'] as String?,
        addedAs = j['entry'] as String?;
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

  /// [error] says what could not be reached (the comma, Connect, or both); the routes found are returned anyway.
  /// [metric] is the comma's km or miles setting, null when the comma cannot be reached.
  Future<({List<RouteInfo> routes, String? error, bool? metric})> routes() async {
    final j = await _call('GET', '/routes');
    return (routes: [for (final r in j['routes']) RouteInfo(r)], error: j['error'] as String?, metric: j['metric'] as bool?);
  }

  Future<Map<String, dynamic>> resolve(RangeRequest r) async => await _call('POST', '/resolve', r.toJson());

  /// [preview] prepares the drive for the window to play instead of encoding an MP4
  Future<Map<String, dynamic>> startJob(RangeRequest r, Map<String, Object?> options, String? output, {bool preview = false}) async =>
      await _call('POST', '/jobs', {...r.toJson(), 'options': options, 'output': output, 'preview': preview});

  Future<Map<String, dynamic>> job(String id) async => await _call('GET', '/jobs/$id');

  Future<Map<String, dynamic>> seek(String jobFile, int frame) async =>
      (await _call('POST', '/preview/seek', {'job_file': jobFile, 'frame': frame})) as Map<String, dynamic>;

  Future<void> addDrive(String text) async => await _call('POST', '/drives/add', {'text': text});

  Future<void> removeDrive(String entry) async => await _call('POST', '/drives/remove', {'text': entry});

  Future<Map<String, dynamic>> settings() async => await _call('GET', '/settings');

  Future<Map<String, dynamic>> changeSettings(Map<String, Object?> changes) async => await _call('PUT', '/settings', changes);

  Future<Map<String, dynamic>> checkHost(String address) async => await _call('POST', '/settings/check-host', {'address': address});

  Future<List<dynamic>> findComma() async => await _call('POST', '/settings/find-comma', {});

  Future<Map<String, dynamic>> createSshKey() async => await _call('POST', '/settings/ssh-key', {});

  Future<Map<String, dynamic>> saveToken(String token) async => await _call('POST', '/settings/token', {'token': token});

  Future<Map<String, dynamic>> clearCache() async => await _call('POST', '/settings/clear-cache', {});

  Future<Map<String, dynamic>> cancel(String id) async => await _call('POST', '/jobs/$id/cancel', {});

  /// the user's answer to a job's question: whether to copy over the comma's metered connection now
  Future<Map<String, dynamic>> answer(String id, bool copyNow) async =>
      await _call('POST', '/jobs/$id/answer', {'copy_now': copyNow});

  /// stop a render early but keep the frames made so far, as a clip marked partial
  Future<Map<String, dynamic>> finish(String id) async => await _call('POST', '/jobs/$id/finish', {});

  void close() => _client.close(force: true);
}
