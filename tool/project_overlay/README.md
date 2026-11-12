# Commands Android project overlay

This directory is the source of truth for the Flutter UI and Android application files copied by \`tool/bootstrap.sh\`.

The Android app uses:
- Dart/Flutter for the user interface.
- Kotlin for Android lifecycle, Shizuku permission and Binder integration.
- Rust for the shell process engine loaded into the Shizuku UserService process through JNI.

The Rust shared library is built for \`arm64-v8a\` by GitHub Actions and placed under \`android/app/src/main/jniLibs\` before the APK is packaged.
