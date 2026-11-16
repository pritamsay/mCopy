"""Exercise HTTP release installation in a marked, isolated workspace prefix.

Run with .venv/bin/python. HOME, current installed apps, login items, Finder
registrations, and real user preferences are never changed by this test.
"""

import functools
import hashlib
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading


project = Path(__file__).resolve().parent.parent
release = project / ".release"
real_app = Path.home() / "Applications/myCopy.app"


def run(command, environment=None, expected=0):
    result = subprocess.run(command, cwd=project, env=environment, text=True, capture_output=True)
    print(result.stdout, end="")
    print(result.stderr, end="")
    if result.returncode != expected:
        raise RuntimeError("Unexpected exit code: " + " ".join(str(part) for part in command))
    return result


def fingerprint(path):
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None


def user_state():
    paths = [real_app / "Contents/MacOS/myCopy", Path.home() / "Library/Preferences/local.pritam.mycopy.plist"]
    support = Path.home() / "Library/Application Support/mCopy"
    if support.exists():
        paths.extend(path for path in support.rglob("*") if path.is_file())
    return {str(path): fingerprint(path) for path in paths}


def assert_removed(prefix):
    for relative in [
        "Applications/myCopy.app",
        "Library/Application Support/mCopy",
        "Library/Preferences/local.pritam.mycopy.plist",
        "Library/Containers/local.pritam.mycopy.finder",
        "Library/Application Scripts/local.pritam.mycopy.finder",
    ]:
        assert not (prefix / relative).exists(), relative


def main():
    before = user_state()
    prefix = Path(tempfile.mkdtemp(prefix="packaging-smoke-", dir=project / ".build"))
    (prefix / ".mcopy-test-root").write_text("isolated test\n")
    installed = prefix / "Applications/myCopy.app"
    executable = installed / "Contents/MacOS/myCopy"
    bad_release = release / "bad-checksum"
    bad_release.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(release / "mCopy-macos-universal.zip", bad_release / "mCopy-macos-universal.zip")
    (bad_release / "SHA256SUMS").write_text("0" * 64 + "  mCopy-macos-universal.zip\n")
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(release))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    environment = os.environ.copy()
    environment["MCOPY_TEST_ROOT"] = str(prefix)
    base = "http://127.0.0.1:" + str(server.server_port)
    try:
        environment["MCOPY_RELEASE_BASE_URL"] = base + "/bad-checksum"
        rejected = run(["/bin/bash", "install.sh"], environment, expected=1)
        assert "checksum did not match" in rejected.stderr
        assert not installed.exists()
        print("PASS: checksum failure rejected before installation.")

        environment["MCOPY_RELEASE_BASE_URL"] = base
        run(["/bin/bash", "install.sh"], environment)
        status = json.loads(run([str(executable), "--status"]).stdout)
        assert status["version"] == "3.1.0"
        assert Path(status["bundlePath"]) == installed
        run([str(executable), "--self-test"])
        run(["/bin/bash", "install.sh"], environment)
        print("PASS: HTTP download, universal app verification, packaged copy/move, and repeat installation.")

        for relative in [
            "Library/Preferences/local.pritam.mycopy.plist",
            "Library/Containers/local.pritam.mycopy.finder/test-data",
            "Library/Application Scripts/local.pritam.mycopy.finder/test-data",
        ]:
            path = prefix / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("isolated state to remove\n")
        run(["/bin/bash", "uninstall.sh"], environment)
        assert_removed(prefix)
        run(["/bin/bash", "uninstall.sh"], environment)
        print("PASS: isolated app/state removal and repeat uninstall.")

        if real_app.exists():
            run(["/usr/bin/ditto", str(real_app), str(installed)])
            run(["/bin/bash", "uninstall.sh"], environment)
            assert_removed(prefix)
            print("PASS: legacy-build cleanup using a verified management bundle in the isolated prefix.")
        assert user_state() == before
        print("PASS: actual installed executable and user data are unchanged.")
    finally:
        server.shutdown()
        server.server_close()
        shutil.rmtree(bad_release)
        shutil.rmtree(prefix)


if __name__ == "__main__":
    main()
