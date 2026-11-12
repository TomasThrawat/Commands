#!/usr/bin/env bash
set -euo pipefail

ROOT="$PWD"

if [[ ! -d "$ROOT/android" ]]; then
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT
  flutter create --empty --platforms=android --org com.hyouka --project-name commands "$TMP_DIR/commands"
  cp -R "$TMP_DIR/commands/." "$ROOT/"
fi

python3 tool/configure_android.py
cp tool/project_overlay/pubspec.yaml pubspec.yaml
mkdir -p lib test
cp tool/project_overlay/lib/main.dart lib/main.dart
cp tool/project_overlay/test/widget_test.dart test/widget_test.dart
mkdir -p android/app/src/main/aidl/com/hyouka/commands
mkdir -p android/app/src/main/kotlin/com/hyouka/commands
mkdir -p android/app/src/main/res/drawable
mkdir -p android/app/src/main/res/values

# Remove template/legacy Java entrypoints before materializing the Kotlin implementations.
rm -f android/app/src/main/java/com/hyouka/commands/MainActivity.java
rm -f android/app/src/main/java/com/hyouka/commands/CommandUserService.java
find android/app/src/main/kotlin -type f -name 'MainActivity.kt' -delete 2>/dev/null || true
find android/app/src/main/kotlin -type f -name 'CommandUserService.kt' -delete 2>/dev/null || true

cp tool/project_overlay/android/app/src/main/AndroidManifest.xml android/app/src/main/AndroidManifest.xml
cp tool/project_overlay/android/app/src/main/aidl/com/hyouka/commands/ICommandService.aidl android/app/src/main/aidl/com/hyouka/commands/ICommandService.aidl
cp tool/project_overlay/android/app/src/main/kotlin/com/hyouka/commands/MainActivity.kt android/app/src/main/kotlin/com/hyouka/commands/MainActivity.kt
cp tool/project_overlay/android/app/src/main/kotlin/com/hyouka/commands/CommandUserService.kt android/app/src/main/kotlin/com/hyouka/commands/CommandUserService.kt
cp tool/project_overlay/android/app/src/main/res/drawable/launch_background.xml android/app/src/main/res/drawable/launch_background.xml
cp tool/project_overlay/android/app/src/main/res/values/colors.xml android/app/src/main/res/values/colors.xml
cp tool/project_overlay/android/app/src/main/res/values/styles.xml android/app/src/main/res/values/styles.xml
cp tool/project_overlay/android/app/proguard-rules.pro android/app/proguard-rules.pro
rm -f analysis_options.yaml

flutter pub get
