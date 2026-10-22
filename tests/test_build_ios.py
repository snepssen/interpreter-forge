"""Exercise the actual installer script against a fake Xcode, without a phone."""
import os
from pathlib import Path
import subprocess

import pytest


@pytest.mark.parametrize("mode,expected_calls,success", [
    ("no_product", 2, False),
    ("clean_recovers", 2, True),
    ("build_fails", 1, False),
])
def test_ios_never_installs_a_stale_product(tmp_path, mode, expected_calls, success):
    if not Path("/usr/libexec/PlistBuddy").exists():
        pytest.skip("Apple build-script checks require macOS")
    ios = tmp_path / "repo/apple/iOS"
    ios.mkdir(parents=True)
    script = ios / "build-ios.sh"
    script.write_bytes((Path(__file__).parents[1] / "apple/iOS/build-ios.sh").read_bytes())
    # The script asks for the voice before it calls xcodebuild. This tree is
    # not the repo, so give it a stub that prints a path and nothing else.
    voice = ios.parent / "scripts" / "polyglot-voice.sh"
    voice.parent.mkdir()
    voice.write_text("#!/bin/sh\nprintf '%s\\n' /tmp/snepssen-polyglot.onnx\n")
    voice.chmod(0o755)
    app = ios / ".build/Build/Products/Release-iphoneos/Interpreter.app"
    app.mkdir(parents=True)
    (app / "Interpreter").write_text("stale app")
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()

    def tool(name, body):
        path = bin_dir / name
        path.write_text("#!/bin/sh\nset -eu\n" + body)
        path.chmod(0o755)

    for name in ("cp", "rsync", "curl", "xcodegen"):
        tool(name, "exit 0\n")
    tool("xcrun", 'echo invoked >> "$INSTALL_TRACE"\nexit 99\n')
    tool("codesign", 'echo verified >> "$SIGN_TRACE"\n')
    tool("xcodebuild", '''echo build >> "$BUILD_TRACE"
case "$*" in
  *"-scheme InterpreterPhone "*) ;;
  *) echo "installer selected the wrong scheme" >&2; exit 66;;
esac
[ "$BUILD_MODE" != build_fails ] || exit 65
case "$*" in
  *"clean build")
    if [ "$BUILD_MODE" = clean_recovers ]; then
      mkdir -p "$TEST_APP/VoiceCore_VoiceCore.bundle/espeak-ng-data"
      echo fresh > "$TEST_APP/Interpreter"
      echo data > "$TEST_APP/VoiceCore_VoiceCore.bundle/espeak-ng-data/phontab"
      cat > "$TEST_APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Interpreter</string>
<key>CFBundleIdentifier</key><string>com.snepssen.interpreter</string>
</dict></plist>
PLIST
    fi;;
esac
''')
    env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", BUILD_MODE=mode,
               TEST_APP=str(app), BUILD_TRACE=str(tmp_path / "builds"),
               INSTALL_TRACE=str(tmp_path / "installs"), SIGN_TRACE=str(tmp_path / "signs"))
    result = subprocess.run(["bash", str(script), "--no-install"] if success else ["bash", str(script)],
                            env=env, capture_output=True, text=True)
    assert (result.returncode == 0) == success, result.stdout + result.stderr
    assert (tmp_path / "builds").read_text().splitlines() == ["build"] * expected_calls
    assert not (tmp_path / "installs").exists()
    if success:
        assert (app / "Interpreter").read_text().strip() == "fresh"
        assert (tmp_path / "signs").read_text().strip() == "verified"
    else:
        assert not app.exists()
        assert not (tmp_path / "signs").exists()
