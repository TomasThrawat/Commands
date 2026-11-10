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
