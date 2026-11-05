// Which drives the list shows. Each part left empty lets every drive through; a drive the app knows nothing about for a
// part that is set (no date, say, for a drive only on the comma whose clock was not set) is left out by that part.

import 'package:opview/studio/studio_api.dart';

/// where a drive can be had from
enum DriveSource { comma, connect, computer }

/// what the replay can show of it: the full camera, or only the small video
enum DriveDetail { full, small }

enum DriveTime { day, night }

/// the user's own drives, or other people's public ones added by hand
enum DriveOwner { mine, added }

class DriveFilter {
  /// days in the drive's own time, both ends included
  final DateTime? from, to;

  /// part of the name of the town it started or ended in, in any case
  final String startsIn, endsIn;

  /// length in segments, about a minute each
  final int? minSegments, maxSegments;

  /// distance in the comma's own units: km, or miles when [metric] is false
  final double? minDistance, maxDistance;

  /// any of these: a drive available from any one of the sources ticked passes
  final Set<DriveSource> sources;
  final Set<DriveDetail> details;
  final Set<DriveTime> times;
  final Set<DriveOwner> owners;

  const DriveFilter({
    this.from,
    this.to,
    this.startsIn = '',
    this.endsIn = '',
    this.minSegments,
    this.maxSegments,
    this.minDistance,
    this.maxDistance,
    this.sources = const {},
    this.details = const {},
    this.times = const {},
    this.owners = const {},
  });

  static const none = DriveFilter();

  bool get isEmpty =>
      from == null &&
      to == null &&
      startsIn.trim().isEmpty &&
      endsIn.trim().isEmpty &&
      minSegments == null &&
      maxSegments == null &&
      minDistance == null &&
      maxDistance == null &&
      sources.isEmpty &&
      details.isEmpty &&
      times.isEmpty &&
      owners.isEmpty;

  /// how many parts are set, for the filter button's badge
  int get count => [
        from != null || to != null,
        startsIn.trim().isNotEmpty,
        endsIn.trim().isNotEmpty,
        minSegments != null || maxSegments != null,
        minDistance != null || maxDistance != null,
        sources.isNotEmpty,
        details.isNotEmpty,
        times.isNotEmpty,
        owners.isNotEmpty,
      ].where((on) => on).length;

  DriveFilter copyWith({
    Object? from = _keep,
    Object? to = _keep,
    String? startsIn,
    String? endsIn,
    Object? minSegments = _keep,
    Object? maxSegments = _keep,
    Object? minDistance = _keep,
    Object? maxDistance = _keep,
    Set<DriveSource>? sources,
    Set<DriveDetail>? details,
    Set<DriveTime>? times,
    Set<DriveOwner>? owners,
  }) =>
      DriveFilter(
        from: from == _keep ? this.from : from as DateTime?,
        to: to == _keep ? this.to : to as DateTime?,
        startsIn: startsIn ?? this.startsIn,
        endsIn: endsIn ?? this.endsIn,
        minSegments: minSegments == _keep ? this.minSegments : minSegments as int?,
        maxSegments: maxSegments == _keep ? this.maxSegments : maxSegments as int?,
        minDistance: minDistance == _keep ? this.minDistance : minDistance as double?,
        maxDistance: maxDistance == _keep ? this.maxDistance : maxDistance as double?,
        sources: sources ?? this.sources,
        details: details ?? this.details,
        times: times ?? this.times,
        owners: owners ?? this.owners,
      );

  bool matches(RouteInfo r, {required bool? metric}) {
    if (from != null || to != null) {
      final day = r.localDate;
      if (day == null) return false;
      if (from != null && day.isBefore(_dayOf(from!))) return false;
      if (to != null && day.isAfter(_dayOf(to!))) return false;
    }
    if (!_town(startsIn, r.startPlace)) return false;
    if (!_town(endsIn, r.endPlace)) return false;
    final segments = r.last - r.first + 1;
    if (minSegments != null && segments < minSegments!) return false;
    if (maxSegments != null && segments > maxSegments!) return false;
    if (minDistance != null || maxDistance != null) {
      final km = r.km;
      if (km == null) return false;
      final distance = metric == false ? km / 1.609344 : km;
      // the list shows one decimal place; a drive shown as 5.0 is in a range that starts or ends at 5
      final shown = (distance * 10).round() / 10;
      if (minDistance != null && shown < minDistance!) return false;
      if (maxDistance != null && shown > maxDistance!) return false;
    }
    if (sources.isNotEmpty &&
        !((sources.contains(DriveSource.comma) && r.onDevice) ||
            (sources.contains(DriveSource.connect) && r.onConnect) ||
            (sources.contains(DriveSource.computer) && r.stored != null))) {
      return false;
    }
    if (details.isNotEmpty && !details.contains(r.detail == 'full' ? DriveDetail.full : DriveDetail.small)) return false;
    if (times.isNotEmpty) {
      final daylight = r.daylight;
      if (daylight == null || !times.contains(daylight ? DriveTime.day : DriveTime.night)) return false;
    }
    if (owners.isNotEmpty && !owners.contains(r.addedAs == null ? DriveOwner.mine : DriveOwner.added)) return false;
    return true;
  }

  static bool _town(String wanted, String? town) {
    final w = wanted.trim().toLowerCase();
    if (w.isEmpty) return true;
    return town != null && town.toLowerCase().contains(w);
  }

  static DateTime _dayOf(DateTime d) => DateTime(d.year, d.month, d.day);
}

const _keep = Object();
