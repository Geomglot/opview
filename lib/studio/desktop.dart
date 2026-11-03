// Opening files, folders and web pages with the computer's own programs: macOS's open, or Windows Explorer

import 'dart:io';

/// what the file manager is called here, for "Show in ..." buttons
String get fileManagerName => Platform.isWindows ? 'Explorer' : 'Finder';

/// a file in its default app, or a web page in the browser
Future<void> openOnDesktop(String target) =>
    // Explorer reports failure (exit code 1) even when it opens the file, so its exit code is not checked
    Process.run(Platform.isWindows ? 'explorer.exe' : 'open', [target]);

/// the file manager, open at the folder holding [path] with the file selected
Future<void> showInFileManager(String path) =>
    // "/select," and the path go as two arguments: a path with spaces gets quoted, and Explorer ignores "/select,..." as one
    Platform.isWindows ? Process.run('explorer.exe', ['/select,', path]) : Process.run('open', ['-R', path]);
