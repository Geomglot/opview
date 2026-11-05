import 'package:flutter_test/flutter_test.dart';
import 'package:opview/studio/drive_filter.dart';
import 'package:opview/studio/studio_api.dart';
import 'package:opview/studio/studio_page.dart';

RouteInfo drive(
        {String route = '0000005a--f16da7af40',
        int first = 0,
        int last = 9,
        bool onDevice = false,
        bool onConnect = true,
        String? date = '2026-11-05',
        String? from = 'Toronto',
        String? to = 'Oakville',
        double? km = 30,
        bool? daylight = true,
        String? stored,
        String detail = 'full',
        String? addedAs}) =>
    RouteInfo({
      'route': route,
      'first': first,
      'last': last,
      'on_device': onDevice,
      'on_connect': onConnect,
      'local_date': date,
      'start_place': from,
      'end_place': to,
      'km': km,
      'daylight': daylight,
      'stored': stored,
      'detail': detail,
      'entry': addedAs,
    });

bool shows(DriveFilter f, RouteInfo r, {bool? metric = true}) => f.matches(r, metric: metric);

void main() {
  test('no filter shows every drive, even one the app knows little about', () {
    expect(DriveFilter.none.isEmpty, isTrue);
    expect(shows(DriveFilter.none, drive(date: null, from: null, km: null, daylight: null)), isTrue);
  });

  test('a date range includes both its days, and leaves out drives with no date', () {
    final f = DriveFilter(from: DateTime(2026, 11, 1), to: DateTime(2026, 11, 5));
    expect(shows(f, drive(date: '2026-11-05')), isTrue);
    expect(shows(f, drive(date: '2026-11-01')), isTrue);
    expect(shows(f, drive(date: '2026-10-31')), isFalse);
    expect(shows(f, drive(date: '2026-11-06')), isFalse);
    expect(shows(f, drive(date: null)), isFalse);
  });

  test('towns match any part of the name, in any case', () {
    expect(shows(const DriveFilter(startsIn: 'toron'), drive()), isTrue);
    expect(shows(const DriveFilter(startsIn: 'Oakville'), drive()), isFalse);
    expect(shows(const DriveFilter(endsIn: ' oak '), drive()), isTrue);
    expect(shows(const DriveFilter(startsIn: 'x'), drive(from: null)), isFalse);
  });

  test('length counts segments, ends included', () {
    expect(shows(const DriveFilter(minSegments: 10), drive(first: 0, last: 9)), isTrue);
    expect(shows(const DriveFilter(minSegments: 11), drive(first: 0, last: 9)), isFalse);
    expect(shows(const DriveFilter(maxSegments: 5), drive(first: 3, last: 7)), isTrue);
    expect(shows(const DriveFilter(maxSegments: 4), drive(first: 3, last: 7)), isFalse);
  });

  test('distance is in the comma\'s units, as the list shows it', () {
    // 30 km is 18.6 miles
    expect(shows(const DriveFilter(minDistance: 20), drive(km: 30)), isTrue);
    expect(shows(const DriveFilter(minDistance: 20), drive(km: 30), metric: false), isFalse);
    expect(shows(const DriveFilter(maxDistance: 18.6), drive(km: 30), metric: false), isTrue);
    expect(shows(const DriveFilter(maxDistance: 1), drive(km: null)), isFalse);
  });

  test('available from any one of the places ticked', () {
    const comma = DriveFilter(sources: {DriveSource.comma});
    expect(shows(comma, drive(onDevice: true, onConnect: false)), isTrue);
    expect(shows(comma, drive(onDevice: false)), isFalse);
    const either = DriveFilter(sources: {DriveSource.comma, DriveSource.computer});
    expect(shows(either, drive(onDevice: false, stored: 'quick')), isTrue);
    expect(shows(either, drive(onDevice: false)), isFalse);
  });

  test('detail, time of day and whose drive', () {
    expect(shows(const DriveFilter(details: {DriveDetail.small}), drive(detail: 'logs')), isTrue);
    expect(shows(const DriveFilter(details: {DriveDetail.small}), drive(detail: 'full')), isFalse);
    expect(shows(const DriveFilter(times: {DriveTime.night}), drive(daylight: false)), isTrue);
    expect(shows(const DriveFilter(times: {DriveTime.night}), drive(daylight: true)), isFalse);
    expect(shows(const DriveFilter(times: {DriveTime.day}), drive(daylight: null)), isFalse);
    expect(shows(const DriveFilter(owners: {DriveOwner.added}), drive(addedAs: 'someone|x')), isTrue);
    expect(shows(const DriveFilter(owners: {DriveOwner.added}), drive()), isFalse);
  });

  test('the badge counts each part set once', () {
    final f = DriveFilter(from: DateTime(2026), to: DateTime(2026, 2), minSegments: 3, maxSegments: 9, times: {DriveTime.day});
    expect(f.count, 3);
    expect(f.copyWith(from: null, to: null).count, 2);
  });

  test('the date button says the range in words', () {
    expect(dateRangeLabel(null, null), 'Any date');
    expect(dateRangeLabel(DateTime(2026, 11, 5), DateTime(2026, 11, 5)), '5 Nov 2026');
    expect(dateRangeLabel(DateTime(2026, 11, 1), DateTime(2026, 11, 5)), '1 Nov 2026 to 5 Nov 2026');
  });
}
