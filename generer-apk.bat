@echo off
setlocal

cd /d "%~dp0"

if not exist "android\gradlew.bat" (
  echo ERREUR : android\gradlew.bat est introuvable.
  exit /b 1
)

pushd android
call gradlew.bat -g "%USERPROFILE%\.gradle" assembleRelease --no-daemon --console=plain -x lintVitalAnalyzeRelease
set "BUILD_EXIT=%ERRORLEVEL%"
popd

if not "%BUILD_EXIT%"=="0" (
  echo.
  echo La generation de l'APK a echoue.
  exit /b %BUILD_EXIT%
)

if not exist "build\app\outputs\flutter-apk\app-release.apk" (
  echo ERREUR : l'APK attendu est introuvable.
  exit /b 1
)

echo.
echo APK genere : %~dp0build\app\outputs\flutter-apk\app-release.apk
exit /b 0
