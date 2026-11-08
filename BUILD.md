# Android frontend and carrier assembly

The APK is assembled from a rebuilt Dart AOT frontend and the exact official Android carrier. The carrier's Android DEX, Flutter engine, VPN core, JNI and SQLite libraries remain unchanged. A Gradle rebuild of the private upstream VPN plugin is not used.

Requirements: Flutter 3.44.9 / Dart 3.12.2, Node.js, network access for pinned dependencies, Android SDK zipalign/apksigner and a signing key of your own. The publication does not include signing keys, local configuration, QA private data or build caches.

From the repository root:

```powershell
flutter pub get
node build-tools/assemble.mjs
node build-tools/fetch-carrier.mjs
node build-tools/package-android.mjs release
zipalign -f -p 4 build/apk/release-unsigned.apk build/apk/release-aligned.apk
apksigner sign --ks YOUR_KEYSTORE --out build/apk/AntiNet-K.apk build/apk/release-aligned.apk
```

The key is supplied locally through the Android signing tool. Your signature and signing timestamps can differ from the published APK. The original carrier is verified by its pinned SHA-256 before packaging. Production assembly always uses lib/main.dart.

Only the Android frontend/bridge and Android project reference are included. Other-platform native projects and test-support entry points are omitted. The two files under lib/app/private are explicit public placeholders: provider lookup is unavailable and upstream telemetry is not initialized.
