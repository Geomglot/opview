import 'package:flutter_test/flutter_test.dart';
import 'package:opview/studio/studio_page.dart';

void main() {
  test('the Cancel question says how much of a fetch has come and how long the rest should take', () {
    Map<String, dynamic> job(num? left) => {
          'message': 'ignored while fetching',
          'fetch': {'what': 'the full files from connect', 'done': 120400000, 'total': 800000000, 'seconds_left': left},
        };
    expect(fetchedSoFar(job(240)), 'Fetched 120 of 800 MB, about 4 min left');
    expect(fetchedSoFar(job(null)), 'Fetched 120 of 800 MB, working out the time left');
    expect(fetchedSoFar({'message': 'preparing the drive', 'fetch': null}), 'preparing the drive');
  });

  test('the time left reads as the server says it', () {
    expect(timeLeft(2), 'almost done');
    expect(timeLeft(42), 'about 40 s left');
    expect(timeLeft(250), 'about 4 min left');
    expect(timeLeft(2 * 3600 + 5 * 60), 'about 2 h 5 min left');
  });
}
