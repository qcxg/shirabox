[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runtimePath = Join-Path $repoRoot 'windows\resources\scrcpy'
$downloadPath = Join-Path $repoRoot 'build\runtime-download'
$archivePath = Join-Path $downloadPath 'scrcpy-win64-v3.3.3.zip'
$expandedPath = Join-Path $downloadPath 'expanded'
$runtimeUrl = 'https://github.com/Genymobile/scrcpy/releases/download/v3.3.3/scrcpy-win64-v3.3.3.zip'
$runtimeSha256 = '4B458D33D0436688C69875CD267CAE6FA8BE08AA3C17772EDF3A940A3DC4B17E'

New-Item -ItemType Directory -Path $downloadPath,$runtimePath -Force | Out-Null
if (-not (Test-Path -LiteralPath $archivePath) -or
    (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash -ne $runtimeSha256) {
    Invoke-WebRequest -Uri $runtimeUrl -OutFile $archivePath
}
if ((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash -ne $runtimeSha256) {
    throw 'Downloaded scrcpy archive does not match the pinned SHA-256.'
}
Expand-Archive -LiteralPath $archivePath -DestinationPath $expandedPath -Force
$packagePath = Join-Path $expandedPath 'scrcpy-win64-v3.3.3'
if (-not (Test-Path -LiteralPath (Join-Path $packagePath 'adb.exe'))) {
    throw 'The scrcpy archive does not contain the expected Windows runtime.'
}
Get-ChildItem -LiteralPath $packagePath | Where-Object {
    $_.Name -ne 'scrcpy-noconsole.vbs'
} | Copy-Item -Destination $runtimePath -Recurse -Force
Write-Host 'scrcpy 3.3.3 and its bundled ADB are ready in windows/resources/scrcpy.'
