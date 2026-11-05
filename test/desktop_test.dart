import 'package:flutter_test/flutter_test.dart';
import 'package:opview/studio/desktop.dart';

void main() {
  test("Linux's file manager is asked to show the file itself, by its file: address", () {
    expect(showItemsArgs('/home/me/Videos/my drive.mp4'), [
      '--session', '--print-reply', '--dest=org.freedesktop.FileManager1', '--type=method_call',
      '/org/freedesktop/FileManager1', 'org.freedesktop.FileManager1.ShowItems',
      'array:string:file:///home/me/Videos/my%20drive.mp4', 'string:',
    ]);
  });
}
