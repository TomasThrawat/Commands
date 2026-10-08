from pathlib import Path
import re

root = Path.cwd()
app = root / "android" / "app"
path = app / "build.gradle.kts"

if not path.exists():
    path = app / "build.gradle"

if not path.exists():
    raise SystemExit("Android app Gradle file not found")

text = path.read_text(encoding="utf-8")

if path.name == "build.gradle.kts":
    text = re.sub(r'namespace\s*=\s*"[^"]+"', 'namespace = "com.hyouka.commands"', text, count=1)
    text = re.sub(r'applicationId\s*=\s*"[^"]+"', 'applicationId = "com.hyouka.commands"', text, count=1)
    text = re.sub(r'minSdk\s*=\s*[^\n]+', 'minSdk = 31', text, count=1)
    if "dev.rikka.shizuku:api" not in text:
        dep = '''\ndependencies {
    implementation("dev.rikka.shizuku:api:13.1.5")
    implementation("dev.rikka.shizuku:provider:13.1.5")
}
'''
        match = re.search(r'(?ms)^dependencies\s*\{\s*\}\s*', text)
        if match:
            text = text[:match.start()] + dep.lstrip("\n") + text[match.end():]
        else:
            text += dep
else:
    text = re.sub(r'namespace\s*[ =]?\s*"[^"]+"', 'namespace "com.hyouka.commands"', text, count=1)
    text = re.sub(r'applicationId\s*[ =]?\s*"[^"]+"', 'applicationId "com.hyouka.commands"', text, count=1)
    text = re.sub(r'minSdk(?:Version)?\s*[ =]?\s*[^\n]+', 'minSdkVersion 31', text, count=1)
    if "dev.rikka.shizuku:api" not in text:
        text += '''
dependencies {
    implementation 'dev.rikka.shizuku:api:13.1.5'
    implementation 'dev.rikka.shizuku:provider:13.1.5'
}
'''

path.write_text(text, encoding="utf-8")

kotlin_main = app / "src" / "main" / "kotlin" / "com" / "hyouka" / "commands" / "MainActivity.kt"
if kotlin_main.exists():
    kotlin_main.unlink()
