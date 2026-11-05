// Opening files, folders and web pages with the computer's own programs: macOS's open, Windows Explorer, or on Linux
// what the desktop has set up (xdg-open, and the file manager call most Linux desktops answer)

import 'dart:io';

/// what the file manager is called here, for "Show in ..." buttons
String get fileManagerName => Platform.isWindows ? 'Explorer' : Platform.isLinux ? 'file manager' : 'Finder';

/// a fixed-width font this computer has; on Linux, fontconfig picks one for the name "monospace"
String get monospaceFont => Platform.isWindows ? 'Consolas' : Platform.isLinux ? 'monospace' : 'Menlo';

/// the install guide for this kind of computer, in the guides folder
String get installGuide => Platform.isWindows ? 'INSTALL-WINDOWS.md' : Platform.isLinux ? 'INSTALL-LINUX.md' : 'INSTALL.md';

/// what the app calls the computer it runs on
String get thisComputer => Platform.isMacOS ? 'this Mac' : 'this computer';

/// a file in its default app, or a web page in the browser
Future<void> openOnDesktop(String target) =>
    // Explorer reports failure (exit code 1) even when it opens the file, so its exit code is not checked
    Process.run(Platform.isWindows ? 'explorer.exe' : Platform.isLinux ? 'xdg-open' : 'open', [target]);

/// the file manager, open at the folder holding [path] with the file selected
Future<void> showInFileManager(String path) async {
  if (Platform.isWindows) {
    // "/select," and the path go as two arguments: a path with spaces gets quoted, and Explorer ignores "/select,..." as one
    await Process.run('explorer.exe', ['/select,', path]);
  } else if (Platform.isLinux) {
    // a desktop whose file manager does not answer the call gets the folder opened, without the file selected
    try {
      if ((await Process.run('dbus-send', showItemsArgs(path))).exitCode == 0) return;
    } on ProcessException {
      // no dbus-send
    }
    await Process.run('xdg-open', [File(path).parent.path]);
  } else {
    await Process.run('open', ['-R', path]);
  }
}

/// the arguments to dbus-send for the file manager call most Linux desktops answer (GNOME Files, KDE's Dolphin, Nemo,
/// Caja, Thunar), which opens the folder holding [path] with the file selected
List<String> showItemsArgs(String path) => [
      '--session', '--print-reply', '--dest=org.freedesktop.FileManager1', '--type=method_call',
      '/org/freedesktop/FileManager1', 'org.freedesktop.FileManager1.ShowItems', 'array:string:${Uri.file(path, windows: false)}', 'string:',
    ];
