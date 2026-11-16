$ErrorActionPreference = 'Stop'

$androidRoot = Join-Path $PSScriptRoot '..\android'
$iosInfo = Join-Path $PSScriptRoot '..\ios\Runner\Info.plist'
if (-not (Test-Path $androidRoot) -or -not (Test-Path $iosInfo)) {
  throw 'Générez d’abord les dossiers natifs avec : flutter create --platforms=android,ios .'
}

$activity = Get-ChildItem (Join-Path $androidRoot 'app\src\main') -Filter 'MainActivity.kt' -Recurse | Select-Object -First 1
if (-not $activity) { throw 'MainActivity.kt introuvable dans android/app/src/main.' }
$source = Get-Content -Raw $activity.FullName
$packageLine = [regex]::Match($source, '(?m)^package\s+[^\r\n]+').Value
if (-not $packageLine) { throw 'Déclaration package Kotlin introuvable dans MainActivity.kt.' }
$replacement = @"
$packageLine

import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity

class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
        super.onCreate(savedInstanceState)
    }
}
"@
Set-Content -LiteralPath $activity.FullName -Value $replacement -Encoding utf8

$manifest = Join-Path $androidRoot 'app\src\main\AndroidManifest.xml'
$manifestText = Get-Content -Raw $manifest
$manifestText = [regex]::Replace($manifestText, '(android:label=")[^"]*(")', '${1}GOPS${2}', 1)
if ($manifestText -notmatch 'android.permission.USE_BIOMETRIC') {
  $replacementPermission = '$1' + "`r`n    <uses-permission android:name=`"android.permission.USE_BIOMETRIC`" />"
  $manifestText = [regex]::Replace($manifestText, '(<manifest\b[^>]*>)', $replacementPermission, 1)
}
Set-Content -LiteralPath $manifest -Value $manifestText -Encoding utf8

$rules = Join-Path $androidRoot 'app\proguard-rules.pro'
if (-not (Test-Path $rules)) { New-Item -ItemType File -Path $rules | Out-Null }
if (-not (Select-String -LiteralPath $rules -SimpleMatch 'net.sqlcipher' -Quiet)) {
  Add-Content -LiteralPath $rules -Value "`n-keep class net.sqlcipher.** { *; }"
}

$podfile = Join-Path $PSScriptRoot '..\ios\Podfile'
if (Test-Path $podfile) {
  $pods = Get-Content -Raw $podfile
  if ($pods -match '(?m)^\s*#\s*platform :ios,') {
    $pods = [regex]::Replace($pods, '(?m)^\s*#\s*platform :ios,.*$', "platform :ios, '13.0'", 1)
  } elseif ($pods -notmatch "platform :ios, '13\.0'") {
    $pods = "platform :ios, '13.0'`n" + $pods
  }
  if ($pods -notmatch '(?m)^\s*use_frameworks!') {
    $pods = [regex]::Replace($pods, "(?m)^(\s*target 'Runner' do\s*)$", '$1' + "`n  use_frameworks!", 1)
  }
  Set-Content -LiteralPath $podfile -Value $pods -Encoding utf8
}

$plist = Get-Content -Raw $iosInfo
$plist = [regex]::Replace($plist, '(<key>CFBundleDisplayName</key>\s*<string>)[^<]*(</string>)', '${1}GOPS${2}', 1)
$entries = @{
  'CFBundleDisplayName' = 'GOPS'
  'NSCameraUsageDescription' = 'GOPS utilise l’appareil photo pour joindre une photographie à une fiche.'
  'NSPhotoLibraryUsageDescription' = 'GOPS permet de choisir une photographie à copier dans son stockage privé.'
  'NSFaceIDUsageDescription' = 'GOPS utilise Face ID pour déverrouiller l’application.'
}
foreach ($key in $entries.Keys) {
  if ($plist -notmatch "<key>$key</key>") {
    $entry = "    <key>$key</key>`n    <string>$($entries[$key])</string>`n"
    $rootDictEnd = $plist.LastIndexOf('</dict>')
    if ($rootDictEnd -lt 0) { throw 'Info.plist invalide : dictionnaire racine introuvable.' }
    $plist = $plist.Insert($rootDictEnd, $entry)
  }
}
Set-Content -LiteralPath $iosInfo -Value $plist -Encoding utf8

$appDelegate = Join-Path $PSScriptRoot '..\ios\Runner\AppDelegate.swift'
if (Test-Path $appDelegate) {
  $swift = Get-Content -Raw $appDelegate
  if ($swift -notmatch 'gopsPrivacyShield') {
    $privacyMethods = @"

    private var gopsPrivacyShield: UIView?

    override func applicationWillResignActive(_ application: UIApplication) {
        super.applicationWillResignActive(application)
        guard let window = window else { return }
        let shield = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        shield.frame = window.bounds
        shield.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(shield)
        gopsPrivacyShield = shield
    }

    override func applicationDidBecomeActive(_ application: UIApplication) {
        gopsPrivacyShield?.removeFromSuperview()
        gopsPrivacyShield = nil
        super.applicationDidBecomeActive(application)
    }
"@
    $lastBrace = $swift.LastIndexOf('}')
    if ($lastBrace -lt 0) { throw 'AppDelegate.swift invalide : accolade finale introuvable.' }
    $swift = $swift.Insert($lastBrace, $privacyMethods + "`n")
    Set-Content -LiteralPath $appDelegate -Value $swift -Encoding utf8
  }
}

Write-Host 'Configuration Android/iOS GOPS appliquée.'
