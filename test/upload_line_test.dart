import 'package:flutter_test/flutter_test.dart';
import 'package:opview/studio/studio_page.dart';

void main() {
  Map<String, dynamic> u(Map<String, dynamic> more) => {'requested': true, 'files': 4, 'uploaded': 1, 'done': false, ...more};

  test('the drive pane says how an upload to Connect is going', () {
    expect(uploadLine(null), isNull);
    expect(uploadLine({'requested': false}), isNull);
    expect(uploadLine(u({'done': true})), 'The full files are on comma Connect now.');
    expect(uploadLine(u({'answered': true, 'current': {'segment': 3, 'file': 'fcamera.hevc', 'progress': 0.42}})),
        'Upload to comma Connect: 1 of 4 files there. Uploading fcamera.hevc of segment 3: 42%.');
    expect(uploadLine(u({'answered': false})), endsWith('The comma is not answering; it uploads once it is online.'));
    expect(uploadLine(u({'answered': true, 'queued': 3, 'metered': true})), endsWith('waiting for an unmetered connection.'));
    expect(uploadLine(u({'answered': true, 'queued': 3, 'metered': false})), endsWith("Waiting in the comma's upload queue."));
    expect(uploadLine(u({'answered': true, 'queued': 0})), endsWith('Waiting for comma Connect to list the uploaded files.'));
  });
}
