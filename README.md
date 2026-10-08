# Commands

Flutter-only Android 12+ shell command runner using the direct Shizuku UserService API.

The app has a pure-black UI with white text/icons, an explicit Run button, selectable output, stdout/stderr separation, exit code, running state, timeout/error handling, and a fixed Save Output button.

Save Output replaces the public Downloads file:

Download/commands.txt

The save path uses MediaStore and does not require broad external-storage permission.

Execution happens only after the user presses Run. The native UserService executes the entered command with sh -c, captures stdout/stderr concurrently, caps returned output at 256 KiB per stream, enforces a 120-second timeout, and returns the exit code.

The project does not use root or the rish execution layer and does not bundle rish_shizuku.dex.

CI installs Flutter 3.47.0 stable, runs pub get, analyze, tests, builds an arm64-only release APK, checks the APK contents, and uploads both the APK and the complete generated Flutter project.

Shizuku must be installed, running, and authorized for Commands before commands can execute.

MIT
