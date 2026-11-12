# Commands

A Flutter Android shell-command app powered by a Shizuku UserService.

## Shell execution

- Commands run through /system/bin/sh -c in the authorized Shizuku UserService.
- There is no automatic command timeout. A command remains active until it exits or you press Stop.
- Stop cancels the active shell process; separately detached child processes may continue running.
- Standard output and standard error are collected separately.
- Output capture is bounded to 256 KiB per stream. Additional output is marked as truncated.
- The shell uses a stable C locale and an Android system/vendor PATH.

## Requirements

Install and start Shizuku, then grant the app permission before running commands. The app does not install Shizuku or grant its permission automatically.

## Build

The GitHub Actions workflow runs Flutter analysis and tests, then builds the ARM64 release APK and packages the generated Flutter project.


## Native architecture

- **Dart / Flutter** owns the user interface, command editor, history, and display of results.
- **Kotlin** owns Android lifecycle, Shizuku permission handling, UserService binding, Binder, preferences, and Downloads storage.
- **Rust** owns shell process creation, stdout/stderr collection, output limits, and command cancellation. The Rust library is loaded by the Shizuku UserService process, so child commands inherit that service process's execution identity.

The Android package currently targets \`arm64-v8a\`. GitHub Actions runs Rust unit tests, builds \`libcommands_engine.so\` for Android ARM64, and packages it into the APK.
