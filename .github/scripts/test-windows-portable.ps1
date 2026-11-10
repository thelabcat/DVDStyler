# Headless smoke test for the portable Windows zip: unzip it, then with PATH
# limited to the portable bin\ folder plus the Windows system folders, have
# DVDStyler generate DVDs into VIDEO_TS folders with `DVDStyler.exe -s`:
#   1. default settings: still-image menu + 5 s title
#   2. mplex on ([Generate] UseMplex=1, UseMplexForMenus=1): still-image
#      menu with background audio + the same title, so mplex has to run
#   3. NTSC project with a 1280x720 H.264 23.976 fps title, so ffmpeg-vbr.bat
#      takes its telecine branch; the title VOB must be top field first
# Each passes if VIDEO_TS.IFO and a VOB exist (plus the per-test checks).
param(
  [Parameter(Mandatory = $true)] [string] $Zip,
  [string] $WorkDir = "$env:RUNNER_TEMP\dvds-test",
  [int] $TimeoutSec = 900
)
$ErrorActionPreference = 'Stop'

Remove-Item -Recurse -Force $WorkDir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $WorkDir | Out-Null
Expand-Archive -Path $Zip -DestinationPath "$WorkDir\app"
$app = (Get-ChildItem -Directory "$WorkDir\app" | Select-Object -First 1).FullName
$bin = Join-Path $app 'bin'
$ini = Join-Path $app 'DVDStyler.ini'
$shippedIni = Get-Content -Raw $ini
Write-Host "Portable folder: $app"

# Clean PATH: the portable folder and Windows only. No MSYS2, Git, etc.
$env:PATH = "$bin;$env:SystemRoot\System32;$env:SystemRoot;$env:SystemRoot\System32\Wbem;$env:SystemRoot\System32\WindowsPowerShell\v1.0"
Write-Host "PATH=$env:PATH"

# Test media made with the bundled ffmpeg.
$media = Join-Path $WorkDir 'media'
New-Item -ItemType Directory -Force $media | Out-Null
function Run-Ffmpeg([string[]] $a) {
  & "$bin\ffmpeg.exe" -hide_banner -loglevel error @a
  if ($LASTEXITCODE -ne 0) { throw "ffmpeg $a failed: $LASTEXITCODE" }
}
Run-Ffmpeg @('-f', 'lavfi', '-i', 'testsrc=size=720x576:rate=25', '-frames:v', '1', '-y', "$media\bg.jpg")
Run-Ffmpeg @('-f', 'lavfi', '-i', 'testsrc=size=720x576:rate=25', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
  '-t', '5', '-target', 'pal-dvd', '-y', "$media\test.mpg")
Run-Ffmpeg @('-f', 'lavfi', '-i', 'sine=frequency=660:sample_rate=48000', '-t', '3', '-c:a', 'mp2', '-b:a', '192k', '-y', "$media\menu.mp2")
Run-Ffmpeg @('-f', 'lavfi', '-i', 'testsrc2=size=1280x720:rate=24000/1001', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
  '-t', '4', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-y', "$media\film24.mp4")

function Test-Generate([string] $name, [string] $iniExtra, [bool] $menuAudio, [bool] $expectMplex,
    [string] $fmt = 'pal', [string] $title = "$media\test.mpg", [bool] $expectTelecine = $false,
    [string] $titleStreams = '') {
  Write-Host ""
  Write-Host "===== $name ====="
  # Test-only settings on top of the shipped DVDStyler.ini. CacheClearPrompt=1
  # clears the transcoding cache at exit without the blocking prompt.
  Set-Content -Path $ini -Value ($shippedIni.TrimEnd() + "`r`nCacheClearPrompt=1`r`n" + $iniExtra)
  Get-Content $ini | Write-Host

  $t = Join-Path $WorkDir $name
  New-Item -ItemType Directory -Force $t, "$t\out", "$t\tmp" | Out-Null
  $audioXml = ''
  if ($menuAudio) { $audioXml = "<audio>$media\menu.mp2</audio>" }
  $vf = 2; $h = 576
  if ($fmt -eq 'ntsc') { $vf = 3; $h = 480 }
  $FMT = $fmt.ToUpper()
  @"
<?xml version="1.0" encoding="utf-8"?>
<dvdstyler format="4" name="TEST" videoFormat="$vf" audioFormat="3" aspectRatio="1">
  <vmgm><menus><video format="$fmt"/><pgc entry="title"><vob pause="inf">$audioXml<menu videoFormat="$FMT" aspectRatio="1">
    <svg width="720" height="$h"><rect width="720" height="$h" id="backgroundColour" fill="#2040a0"/>
    <image width="720" height="$h" id="background" xlink:href="$media\bg.jpg"/></svg>
  </menu></vob></pgc></menus></vmgm>
  <titleset><titles><video format="$fmt"/><pgc><vob file="$title">$titleStreams</vob></pgc></titles></titleset>
</dvdstyler>
"@ | Set-Content -Encoding utf8 "$t\test.dvds"

  $log = "$t\dvdstyler-stderr.txt"
  $p = Start-Process -FilePath "$bin\DVDStyler.exe" -PassThru -WorkingDirectory $bin `
    -ArgumentList @('-s', '-e', '-t', "`"$t\tmp`"", '-o', "`"$t\out`"", "`"$t\test.dvds`"") `
    -RedirectStandardError $log -RedirectStandardOutput "$t\dvdstyler-stdout.txt"
  $finished = $p.WaitForExit($TimeoutSec * 1000)
  if (-not $finished) {
    Write-Host "::error::$name : DVDStyler did not exit within $TimeoutSec s; taking a screenshot"
    try {
      Add-Type -AssemblyName System.Windows.Forms, System.Drawing
      $s = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
      $bmp = New-Object System.Drawing.Bitmap $s.Width, $s.Height
      [System.Drawing.Graphics]::FromImage($bmp).CopyFromScreen($s.Location, [System.Drawing.Point]::Empty, $s.Size)
      $bmp.Save("$t\hang-screenshot.png")
    } catch { Write-Host "screenshot failed: $_" }
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
  }
  Write-Host "---- DVDStyler stderr ($name) ----"
  $text = Get-Content -Raw $log -ErrorAction SilentlyContinue
  Write-Host $text
  Write-Host "---- end ----"

  $vts = "$t\out\VIDEO_TS"
  Get-ChildItem -Recurse "$t\out" -ErrorAction SilentlyContinue | Format-Table FullName, Length -AutoSize | Out-String | Write-Host
  $ifo = Test-Path "$vts\VIDEO_TS.IFO"
  $vobs = @(Get-ChildItem "$vts\*.VOB" -ErrorAction SilentlyContinue)
  $ok = $finished -and $ifo -and $vobs.Count -gt 0
  if ($expectMplex) {
    $ranMplex = $text -match 'Executing command: .*mplex'
    $mplexFailed = $text -match "Execution of command '[^']*mplex"
    Write-Host "mplex ran: $ranMplex, mplex failed: $mplexFailed"
    $ok = $ok -and $ranMplex -and -not $mplexFailed
  }
  if ($expectTelecine) {
    $ranTelecine = $text -match 'telecine,setfield=tff'
    $fo = ''
    if (Test-Path "$vts\VTS_01_1.VOB") {
      $fo = (& "$bin\ffprobe.exe" -v error -select_streams v:0 -show_entries stream=field_order,r_frame_rate -of default=nw=1 "$vts\VTS_01_1.VOB") -join ' '
    }
    Write-Host "telecine in command: $ranTelecine; title VOB: $fo"
    $ok = $ok -and $ranTelecine -and ($fo -match 'field_order=tt')
  }
  if ($ok) { Write-Host "PASS ($name): VIDEO_TS.IFO and $($vobs.Count) VOB file(s) generated" }
  else { Write-Host "::error::FAIL ($name): finished=$finished VIDEO_TS.IFO=$ifo VOBs=$($vobs.Count)" }
  return $ok
}

$r1 = Test-Generate 'default' '' $false $false
$r2 = Test-Generate 'mplex' "[Generate]`r`nUseMplex=1`r`nUseMplexForMenus=1`r`n" $true $true
# Destination formats as the GUI saves them for a non-DVD source: video
# NTSC (3), audio AC3 (3), so the title is re-encoded via ffmpeg-vbr.bat.
$r3 = Test-Generate 'telecine' '' $false $false 'ntsc' "$media\film24.mp4" $true '<video format="3"/><audio format="3"/>'
Set-Content -Path $ini -Value $shippedIni -NoNewline
Write-Host "results: default=$r1 mplex=$r2 telecine=$r3"
if ($r1 -and $r2 -and $r3) { Write-Host "ALL PASS"; exit 0 }
exit 1
