# OPRivView Replay: build the Windows program with its server and ffmpeg beside it, and zip it for release.
# The Windows counterpart of "make dmg" in the Makefile. Run from the replay folder:
#   powershell -ExecutionPolicy Bypass -File packaging\build_windows.ps1 [-FfmpegDir <folder>] [-SkipFlutter]
# Needs Flutter (with Visual Studio's C++ tools), the replay .venv with requirements.txt installed, and an ffmpeg folder
# holding ffmpeg.exe, ffprobe.exe, COPYING.LGPLv2.1 and ffmpeg-8.1.tar.xz (default build\ffmpeg-win).
# Leaves dist\OPRivView Replay\ and dist\OPRivView-Replay-<version>-Windows.zip.
param(
  [string]$FfmpegDir = "build\ffmpeg-win",
  [switch]$SkipFlutter  # reuse the last Flutter build, when only the server or packaging changed
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
$version = ((Select-String -Path "$repo\pubspec.yaml" -Pattern '^version:\s*([^+\s]+)').Matches[0].Groups[1].Value)
$out = "dist\OPRivView Replay"
$zip = "dist\OPRivView-Replay-$version-Windows.zip"

foreach ($f in "ffmpeg.exe", "ffprobe.exe", "COPYING.LGPLv2.1", "ffmpeg-8.1.tar.xz") {
  if (-not (Test-Path "$FfmpegDir\$f")) { throw "$FfmpegDir\$f is missing: build ffmpeg first (see the top of this file)" }
}
if (-not (Test-Path $python)) { throw "no replay\.venv: create it and pip install -r requirements.txt" }

Run "server (PyInstaller)" { & "$replay\.venv\Scripts\pyinstaller.exe" packaging\server.spec --distpath dist --workpath build -y --log-level WARN }
if (-not $SkipFlutter) {
  Push-Location $repo
  try { Run "app (Flutter)" { flutter build windows --release -t lib/main_replay.dart } } finally { Pop-Location }
}

Write-Host "== putting it together in $out"
if (Test-Path $out) { Remove-Item -Recurse -Force $out }
New-Item -ItemType Directory $out | Out-Null
Copy-Item -Recurse "$repo\build\windows\x64\runner\Release\*" $out
Copy-Item -Recurse "dist\oprivview-replay-server" $out
New-Item -ItemType Directory "$out\ffmpeg" | Out-Null
Copy-Item "$FfmpegDir\ffmpeg.exe", "$FfmpegDir\ffprobe.exe" "$out\ffmpeg"
Run "licence notices" { & $python packaging\write_notices.py "$out\licenses" $FfmpegDir }
Copy-Item packaging\windows-read-me.txt "$out\Read Me First.txt"

# the app finds its server and ffmpeg beside itself (lib/studio/sidecar.dart); check they are where it looks
foreach ($f in "OPRivViewReplay.exe", "oprivview-replay-server\oprivview-replay-server.exe", "ffmpeg\ffmpeg.exe", "ffmpeg\ffprobe.exe",
                "data\app.so", "licenses\THIRD-PARTY-NOTICES.txt") {
  if (-not (Test-Path "$out\$f")) { throw "$out\$f is missing" }
}

Write-Host "== zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path $out -DestinationPath $zip -CompressionLevel Optimal
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
$mb = [math]::Round((Get-Item $zip).Length / 1MB)
Write-Host "Built: $replay\$out"
Write-Host "Zip:   $replay\$zip ($mb MB)"
Write-Host "SHA-256 $hash"
