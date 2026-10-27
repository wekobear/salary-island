#!/usr/bin/env python3
"""Build only the explicitly authorized local non-sandboxed Debug candidate.

Never launch/install, query accounts, change OS settings, or change Release.
Uses the candidate-only SalaryStoragePolicy directory. Network access by an
actual candidate still requires per-source, per-send consent; auto refresh is OFF.
"""
from pathlib import Path
import json
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
DERIVED = ROOT / "work/live-candidate-build"
BUNDLE = "local.salaryisland.ai-review.20261027"


def run(*args, **kwargs):
    return subprocess.run(args, cwd=ROOT, check=True, **kwargs)


def main():
    original = plistlib.loads((ROOT / "boringNotch/boringNotch.entitlements").read_bytes())
    candidate_file = ROOT / "boringNotch/boringNotch-live-candidate.entitlements"
    candidate = plistlib.loads(candidate_file.read_bytes())
    assert original["com.apple.security.app-sandbox"] is True
    assert candidate["com.apple.security.app-sandbox"] is False
    assert {**candidate, "com.apple.security.app-sandbox": True} == original
    DERIVED.mkdir(parents=True, exist_ok=True)
    with (DERIVED / "build.log").open("wb") as log:
        run("xcodebuild", "-project", "boringNotch.xcodeproj", "-scheme", "boringNotch",
            "-configuration", "Debug", "-derivedDataPath", str(DERIVED),
            "-clonedSourcePackagesDirPath", str(ROOT / "work/offline-dependencies"),
            "-disableAutomaticPackageResolution", "CODE_SIGNING_ALLOWED=NO",
            "ENABLE_APP_SANDBOX=NO", "build", stdout=log, stderr=subprocess.STDOUT)
    app = DERIVED / "Build/Products/Debug/薪动日常.app"
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    assert info["CFBundleIdentifier"] == BUNDLE
    for framework in sorted((app / "Contents/Frameworks").glob("*.framework")):
        run("codesign", "--force", "--deep", "--sign", "-", "--preserve-metadata=entitlements", str(framework),
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    run("codesign", "--force", "--sign", "-", "--entitlements",
        str(ROOT / "BoringNotchXPCHelper/BoringNotchXPCHelper.entitlements"),
        str(app / "Contents/XPCServices/BoringNotchXPCHelper.xpc"),
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    resolved = plistlib.loads(candidate_file.read_text().replace("$(PRODUCT_BUNDLE_IDENTIFIER)", BUNDLE).encode())
    with tempfile.TemporaryDirectory(prefix="salary-live-sign-") as temporary:
        entitlements = Path(temporary) / "candidate.entitlements"
        entitlements.write_bytes(plistlib.dumps(resolved))
        run("codesign", "--force", "--sign", "-", "--entitlements", str(entitlements), str(app),
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    run("codesign", "--verify", "--deep", "--strict", str(app), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    actual = plistlib.loads(run("codesign", "-d", "--entitlements", ":-", str(app),
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout)
    assert actual == resolved
    # Undo Xcode's registration of only this owned output; never touch installed apps.
    registrar = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    unregistered = subprocess.run([registrar, "-u", str(app)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if unregistered.returncode:
        assert b"-10814" in unregistered.stdout + unregistered.stderr
        registry = run(registrar, "-dump", stdout=subprocess.PIPE).stdout
        assert str(app).encode() not in registry
    record = {"bundleIdentifier": BUNDLE, "appSandbox": False, "signature": "ad-hoc",
              "notarized": False, "deepStrictVerify": "passed", "launched": False, "installed": False,
              "sourceCommit": run("git", "rev-parse", "HEAD", stdout=subprocess.PIPE).stdout.decode().strip(),
              "sourceWasDirty": bool(run("git", "status", "--porcelain", stdout=subprocess.PIPE).stdout)}
    (DERIVED / "verification.json").write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps(record))


if __name__ == "__main__":
    main()
