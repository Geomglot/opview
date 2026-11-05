# GeoRivView Replay: build the Windows program with its server and ffmpeg beside it, and its installer for release.
# The Windows counterpart of "make dmg" in the Makefile. Run from the replay folder:
#   powershell -ExecutionPolicy Bypass -File packaging\build_windows.ps1 [-Version <v>] [-BuildNumber <n>]
#     [-FfmpegDir <folder>] [-SkipFlutter] [-SkipInstaller]
# Needs Flutter (with Visual Studio's C++ tools), the replay .venv with requirements.txt installed, an ffmpeg folder
# holding ffmpeg.exe, ffprobe.exe, COPYING.LGPLv2.1 and ffmpeg-8.1.tar.xz (default build\ffmpeg-win), and Inno Setup 6
# for the installer (winget install JRSoftware.InnoSetup).
# The version is replay\VERSION with "-dev" on the end, which the app takes as a local build (its updater stays off);
# the release workflow passes the full one, e.g. -Version 0.1.2-test.1, and its run number as -BuildNumber.
# Leaves dist\GeoRivView Replay\ and dist\GeoRivView-Replay-<version>-Windows.exe.
param(
  [string]$Version,
  [int]$BuildNumber = 1,
  [string]$FfmpegDir = "build\ffmpeg-win",
  [switch]$SkipFlutter,  # reuse the last Flutter build, when only the server or packaging changed
  [switch]$SkipInstaller  # only the program folder
)
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Run([string]$what, [scriptblock]$command) {
  Write-Host "== $what"
  & $command
  if ($LASTEXITCODE) { throw "$what failed (exit $LASTEXITCODE)" }
}

$replay = (Resolve-Path "$PSScriptRoot\..").Path
$repo = (Resolve-Path "$replay\..").Path
Set-Location $replay
$python = "$replay\.venv\Scripts\python.exe"
$base = (Get-Content "$replay\VERSION" -TotalCount 1).Trim()
if (-not $Version) { $Version = "$base-dev" }
if ($Version -notmatch "^$([regex]::Escape($base))(-[0-9A-Za-z.]+)?$") { throw "-Version $Version does not start with replay\VERSION ($base)" }
if ($base -notmatch '^\d+\.\d+\.\d+$') { throw "replay\VERSION ($base) must be three numbers, such as 0.1.2" }
$out = "dist\GeoRivView Replay"
$installer = "dist\GeoRivView-Replay-$Version-Windows.exe"

foreach ($f in "ffmpeg.exe", "ffprobe.exe", "COPYING.LGPLv2.1", "ffmpeg-8.1.tar.xz") {
  if (-not (Test-Path "$FfmpegDir\$f")) { throw "$FfmpegDir\$f is missing: build ffmpeg first (see the top of this file)" }
}
if (-not (Test-Path $python)) { throw "no replay\.venv: create it and pip install -r requirements.txt" }

Run "server (PyInstaller)" { & "$replay\.venv\Scripts\pyinstaller.exe" packaging\server.spec --distpath dist --workpath build -y --log-level WARN }
if (-not $SkipFlutter) {
  Push-Location $repo
  # --build-name and --build-number are what Windows shows in the file's properties; numbers only, so no test number
  try {
    Run "app (Flutter)" {
      flutter build windows --release -t lib/main_replay.dart --build-name=$base --build-number=$BuildNumber `
        --dart-define=OPRIVVIEW_REPLAY_VERSION=$Version
    }
  } finally { Pop-Location }
}

Write-Host "== putting it together in $out"
if (Test-Path $out) { Remove-Item -Recurse -Force $out }
New-Item -ItemType Directory $out | Out-Null
Copy-Item -Recurse "$repo\build\windows\x64\runner\Release\*" $out
Copy-Item -Recurse "dist\oprivview-replay-server" $out
New-Item -ItemType Directory "$out\ffmpeg" | Out-Null
Copy-Item "$FfmpegDir\ffmpeg.exe", "$FfmpegDir\ffprobe.exe" "$out\ffmpeg"
Run "licence notices" { & $python packaging\write_notices.py "$out\licenses" $FfmpegDir }

# the app finds its server and ffmpeg beside itself (lib/studio/sidecar.dart); check they are where it looks
foreach ($f in "OPRivViewReplay.exe", "oprivview-replay-server\oprivview-replay-server.exe", "ffmpeg\ffmpeg.exe", "ffmpeg\ffprobe.exe",
                "data\app.so", "licenses\THIRD-PARTY-NOTICES.txt") {
  if (-not (Test-Path "$out\$f")) { throw "$out\$f is missing" }
}

Write-Host "Built: $replay\$out ($Version)"
if ($SkipInstaller) { return }

$iscc = @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
          "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
$onPath = Get-Command ISCC.exe -ErrorAction SilentlyContinue
if (-not $iscc -and $onPath) { $iscc = $onPath.Source }
if (-not $iscc) { throw "Inno Setup 6 is needed for the installer: winget install JRSoftware.InnoSetup (or use -SkipInstaller)" }
if (Test-Path $installer) { Remove-Item -Force $installer }
Run "installer (Inno Setup)" {
  & $iscc /Q "/DAppVersion=$Version" "/DNumericVersion=$base.$BuildNumber" "/DSourceDir=$replay\$out" packaging\windows-installer.iss
}
if (-not (Test-Path $installer)) { throw "Inno Setup did not make $installer" }
$hash = (Get-FileHash $installer -Algorithm SHA256).Hash.ToLower()
$mb = [math]::Round((Get-Item $installer).Length / 1MB)
Write-Host "Installer: $replay\$installer ($mb MB)"
Write-Host "SHA-256 $hash"
