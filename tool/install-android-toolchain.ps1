$ErrorActionPreference = 'Stop'

$sdkRoot = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
$installHome = Join-Path $env:LOCALAPPDATA 'dev'
$jdkRoot = Join-Path $installHome 'jdk17'
$downloadHome = Join-Path $env:LOCALAPPDATA 'Downloads'
$cliArchive = Join-Path $downloadHome 'commandlinetools-win-15859902_latest.zip'
$jdkArchive = Join-Path $downloadHome 'temurin17-windows-x64.zip'
$cliStage = Join-Path $installHome 'android-cli-stage'
$jdkStage = Join-Path $installHome 'jdk17-stage'

if (Test-Path $sdkRoot) { throw "Android SDK directory already exists; stopping to preserve it: $sdkRoot" }
if (Test-Path $jdkRoot) { throw "JDK directory already exists; stopping to preserve it: $jdkRoot" }

New-Item -ItemType Directory -Force -Path $downloadHome, $installHome, (Join-Path $sdkRoot 'cmdline-tools\latest') | Out-Null
Invoke-WebRequest -Uri 'https://dl.google.com/android/repository/commandlinetools-win-15859902_latest.zip' -OutFile $cliArchive
$cliHash = (Get-FileHash -LiteralPath $cliArchive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($cliHash -ne '90ae805d20434428bffcb699c290860f19bb5f66a67e6b330067e3de801fb04a') {
  throw "Android command line tools checksum mismatch: $cliHash"
}

Invoke-WebRequest -Uri 'https://api.adoptium.net/v3/binary/latest/17/ga/windows/x64/jdk/hotspot/normal/eclipse?project=jdk' -OutFile $jdkArchive
New-Item -ItemType Directory -Force -Path $cliStage, $jdkStage | Out-Null
Expand-Archive -LiteralPath $cliArchive -DestinationPath $cliStage
Expand-Archive -LiteralPath $jdkArchive -DestinationPath $jdkStage
Move-Item -Path (Join-Path $cliStage 'cmdline-tools\*') -Destination (Join-Path $sdkRoot 'cmdline-tools\latest')

$jdkCandidate = Get-ChildItem -LiteralPath $jdkStage -Directory |
  Where-Object { Test-Path (Join-Path $_.FullName 'bin\java.exe') } |
  Select-Object -First 1
if (-not $jdkCandidate) { throw 'Could not find java.exe in the downloaded Temurin archive.' }
Move-Item -LiteralPath $jdkCandidate.FullName -Destination $jdkRoot

$sdkManager = Join-Path $sdkRoot 'cmdline-tools\latest\bin\sdkmanager.bat'
$avdManager = Join-Path $sdkRoot 'cmdline-tools\latest\bin\avdmanager.bat'
$env:JAVA_HOME = $jdkRoot
$env:ANDROID_HOME = $sdkRoot
$env:ANDROID_SDK_ROOT = $sdkRoot
$env:Path = "$jdkRoot\bin;$sdkRoot\cmdline-tools\latest\bin;$sdkRoot\platform-tools;$sdkRoot\emulator;C:\Users\pieci\AppData\Local\dev\flutter\bin;C:\Program Files\Git\cmd;$env:Path"

# The user selected the emulator setup option after being told Android SDK licenses must be accepted.
$licenseAnswers = 1..30 | ForEach-Object { 'y' }
$licenseAnswers | & $sdkManager "--sdk_root=$sdkRoot" --licenses
if ($LASTEXITCODE -ne 0) { throw 'Android SDK license setup failed.' }

& $sdkManager "--sdk_root=$sdkRoot" --install `
  'platform-tools' `
  'platforms;android-36' `
  'build-tools;36.0.0' `
  'emulator' `
  'ndk;28.2.13676358' `
  'cmake;3.31.1' `
  'system-images;android-36;google_apis;x86_64'
if ($LASTEXITCODE -ne 0) { throw 'Android SDK package installation failed.' }

[Environment]::SetEnvironmentVariable('JAVA_HOME', $jdkRoot, 'User')
[Environment]::SetEnvironmentVariable('ANDROID_HOME', $sdkRoot, 'User')
[Environment]::SetEnvironmentVariable('ANDROID_SDK_ROOT', $sdkRoot, 'User')
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$pathParts = @($userPath -split ';' | Where-Object { $_ })
foreach ($entry in @("$jdkRoot\bin", "$sdkRoot\cmdline-tools\latest\bin", "$sdkRoot\platform-tools", "$sdkRoot\emulator")) {
  if ($pathParts -notcontains $entry) { $pathParts += $entry }
}
[Environment]::SetEnvironmentVariable('Path', ($pathParts -join ';'), 'User')

$flutter = 'C:\Users\pieci\AppData\Local\dev\flutter\bin\flutter.bat'
& $flutter config --android-sdk $sdkRoot
if ($LASTEXITCODE -ne 0) { throw 'Flutter could not be configured with the Android SDK.' }

$avdInput = 'no'
$avdInput | & $avdManager create avd --name 'GOPS_API_36' --package 'system-images;android-36;google_apis;x86_64'
if ($LASTEXITCODE -ne 0) { throw 'Android virtual device creation failed.' }

Write-Output "Android SDK and GOPS_API_36 emulator installed at $sdkRoot."
