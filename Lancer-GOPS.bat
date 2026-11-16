@echo off
setlocal
title Lancer GOPS sur Android

cd /d "%~dp0"

set "FLUTTER_ROOT=%LOCALAPPDATA%\dev\flutter"
set "ANDROID_SDK_ROOT=%LOCALAPPDATA%\Android\Sdk"
set "ANDROID_HOME=%ANDROID_SDK_ROOT%"
set "JAVA_HOME=%LOCALAPPDATA%\dev\jdk17"
set "ANDROID_AVD_HOME=%USERPROFILE%\.android\avd"
set "AVD_NAME=GOPS_API_36"
set "EMULATOR=%ANDROID_SDK_ROOT%\emulator\emulator.exe"
set "ADB=%ANDROID_SDK_ROOT%\platform-tools\adb.exe"

if not exist "%FLUTTER_ROOT%\bin\flutter.bat" (
  echo Flutter est introuvable : "%FLUTTER_ROOT%"
  pause
  exit /b 1
)
if not exist "%EMULATOR%" (
  echo L'emulateur Android est introuvable : "%EMULATOR%"
  pause
  exit /b 1
)
if not exist "%ANDROID_AVD_HOME%\%AVD_NAME%.ini" (
  echo L'AVD %AVD_NAME% est introuvable dans "%ANDROID_AVD_HOME%".
  pause
  exit /b 1
)

set "PATH=%FLUTTER_ROOT%\bin;%JAVA_HOME%\bin;%ANDROID_SDK_ROOT%\platform-tools;%ANDROID_SDK_ROOT%\emulator;%ProgramFiles%\Git\cmd;%PATH%"

echo Demarrage de l'emulateur %AVD_NAME%...
start "GOPS Android Emulator" "%EMULATOR%" -avd "%AVD_NAME%" -no-boot-anim

echo Attente du demarrage d'Android...
:wait_adb
"%ADB%" get-state >nul 2>&1
if errorlevel 1 (
  timeout /t 3 /nobreak >nul
  goto wait_adb
)

:wait_boot
for /f "delims=" %%B in ('"%ADB%" shell getprop sys.boot_completed 2^>nul') do set "BOOTED=%%B"
if not "%BOOTED%"=="1" (
  timeout /t 3 /nobreak >nul
  goto wait_boot
)

echo Compilation, installation et lancement de GOPS...
call "%FLUTTER_ROOT%\bin\flutter.bat" run -d emulator-5554
if errorlevel 1 (
  echo.
  echo Le lancement a echoue. Consultez le message d'erreur ci-dessus.
  pause
  exit /b 1
)

endlocal
