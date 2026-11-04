// Which version of OPRivView Replay this is. replay/VERSION holds the version being worked towards (e.g. 0.1.2); a release
// build adds the tag's test number (0.1.2-test.1) and local builds add "-dev" (Makefile, packaging/build_windows.ps1),
// passed in with --dart-define. A bare `flutter run` has none.

const replayVersion = String.fromEnvironment('OPRIVVIEW_REPLAY_VERSION');

/// a build made by the release workflow from a `replay-v<version>` tag, rather than a local or development one
bool get isReleaseBuild => replayVersion.isNotEmpty && !replayVersion.endsWith('-dev');

/// where this build's guides are on GitHub: a release reads the guides of its own tag, so an older copy of the app does
/// not describe newer features; anything else reads the branch
String get guidesUrl =>
    'https://github.com/Geomglot/opview/blob/${isReleaseBuild ? 'replay-v$replayVersion' : 'rivian-support'}/replay/docs';
