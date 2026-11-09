# Headless smoke test for the portable Windows zip: unzip it, then with PATH
# limited to the portable bin\ folder plus the Windows system folders, have
# DVDStyler generate a DVD (still-image menu + 5 s title) into a VIDEO_TS
# folder with `DVDStyler.exe -s`. Passes if VIDEO_TS.IFO and a VOB exist.
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
Write-Host "Portable folder: $app"

# Clean PATH: the portable folder and Windows only. No MSYS2, Git, etc.
$env:PATH = "$bin;$env:SystemRoot\System32;$env:SystemRoot;$env:SystemRoot\System32\Wbem;$env:SystemRoot\System32\WindowsPowerShell\v1.0"
Write-Host "PATH=$env:PATH"

$t = Join-Path $WorkDir 'proj'
New-Item -ItemType Directory -Force $t, "$t\out", "$t\tmp" | Out-Null

# Test media made with the bundled ffmpeg.
& "$bin\ffmpeg.exe" -hide_banner -loglevel error -f lavfi -i "testsrc=size=720x576:rate=25" `
  -frames:v 1 -y "$t\bg.jpg"
if ($LASTEXITCODE -ne 0) { throw "ffmpeg (bg.jpg) failed: $LASTEXITCODE" }
& "$bin\ffmpeg.exe" -hide_banner -loglevel error -f lavfi -i "testsrc=size=720x576:rate=25" `
  -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 5 -target pal-dvd -y "$t\test.mpg"
if ($LASTEXITCODE -ne 0) { throw "ffmpeg (test.mpg) failed: $LASTEXITCODE" }

$bgPath = "$t\bg.jpg"; $mpgPath = "$t\test.mpg"
@"
<?xml version="1.0" encoding="utf-8"?>
<dvdstyler format="4" name="TEST" videoFormat="2" audioFormat="3" aspectRatio="1">
  <vmgm><menus><video format="pal"/><pgc entry="title"><vob pause="inf"><menu videoFormat="PAL" aspectRatio="1">
    <svg width="720" height="576"><rect width="720" height="576" id="backgroundColour" fill="#2040a0"/>
    <image width="720" height="576" id="background" xlink:href="$bgPath"/></svg>
  </menu></vob></pgc></menus></vmgm>
  <titleset><titles><video format="pal"/><pgc><vob file="$mpgPath"/></pgc></titles></titleset>
</dvdstyler>
"@ | Set-Content -Encoding utf8 "$t\test.dvds"

$log = "$t\dvdstyler-stderr.txt"
$p = Start-Process -FilePath "$bin\DVDStyler.exe" -PassThru -WorkingDirectory $bin `
  -ArgumentList @('-s', '-e', '-t', "`"$t\tmp`"", '-o', "`"$t\out`"", "`"$t\test.dvds`"") `
  -RedirectStandardError $log -RedirectStandardOutput "$t\dvdstyler-stdout.txt"
$finished = $p.WaitForExit($TimeoutSec * 1000)
if (-not $finished) {
  Write-Host "::error::DVDStyler did not exit within $TimeoutSec s; taking a screenshot"
  try {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $s = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap $s.Width, $s.Height
    [System.Drawing.Graphics]::FromImage($bmp).CopyFromScreen($s.Location, [System.Drawing.Point]::Empty, $s.Size)
    $bmp.Save("$t\hang-screenshot.png")
  } catch { Write-Host "screenshot failed: $_" }
  Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
}
Write-Host "---- DVDStyler stderr ----"
Get-Content $log -ErrorAction SilentlyContinue
Write-Host "---- end ----"
Write-Host "exit code: $($p.ExitCode)"

$vts = "$t\out\VIDEO_TS"
Get-ChildItem -Recurse "$t\out" -ErrorAction SilentlyContinue | Format-Table FullName, Length -AutoSize | Out-String | Write-Host
$ifo = Test-Path "$vts\VIDEO_TS.IFO"
$vobs = @(Get-ChildItem "$vts\*.VOB" -ErrorAction SilentlyContinue)
if ($finished -and $ifo -and $vobs.Count -gt 0) {
  Write-Host "PASS: VIDEO_TS.IFO and $($vobs.Count) VOB file(s) generated"
  exit 0
}
Write-Host "::error::FAIL: finished=$finished VIDEO_TS.IFO=$ifo VOBs=$($vobs.Count)"
exit 1
