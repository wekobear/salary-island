#!/usr/bin/env python3
"""Build an offline Release from clean HEAD. Never launch, install or publish it."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
VERSION = "0.1.9"
BUILD = "14"
BUNDLE = "local.salaryisland.preview"
XPC_BUNDLE = BUNDLE + ".BoringNotchXPCHelper"


def run(*args, capture=False, **kwargs):
    if capture:
        kwargs["stdout"] = subprocess.PIPE
        kwargs["text"] = True
    return subprocess.run([str(x) for x in args], cwd=ROOT, check=True, **kwargs).stdout


def clean_commit():
    if run("git", "status", "--porcelain", capture=True).strip():
        raise RuntimeError("Commit all intended changes and keep the working tree clean before packaging")
    return run("git", "rev-parse", "HEAD", capture=True).strip()


def in_work(value):
    path = Path(value).expanduser().resolve()
    path.relative_to((ROOT / "work").resolve())
    return path


def verify_info(bundle_path, expected_id):
    with (bundle_path / "Contents/Info.plist").open("rb") as file:
        info = plistlib.load(file)
    expected = {"CFBundleIdentifier": expected_id, "CFBundleShortVersionString": VERSION,
                "CFBundleVersion": BUILD}
    if any(str(info.get(key)) != value for key, value in expected.items()):
        raise RuntimeError("Unexpected Release identity/version: " + bundle_path.name)
    return bundle_path / "Contents/MacOS" / info["CFBundleExecutable"]


def verify_entitlements(bundle_path, expected):
    result = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(bundle_path)],
                            check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if plistlib.loads(result.stdout) != expected:
        raise RuntimeError("Entitlements differ from the reviewed source")


def scan_files(paths, label):
    # No credentials are read. Only source/archive contents and generated products
    # are checked. Diagnostics report the offending relative filename, never data.
    local_needles = [str(Path.home()).encode(), str(ROOT).encode()]
    user_path = rb"/Users/" + rb"[^/\s\x00]{1,80}/"
    temporary_paths = [b"/".join(parts) for parts in
                       [[b"", b"private", b"var", b"folders", b""], [b"", b"var", b"folders", b""]]]
    suspicious = re.compile(b"|".join([user_path] + [re.escape(p) for p in temporary_paths] +
        [rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----", rb"ghp_[A-Za-z0-9]{30,}", rb"sk-[A-Za-z0-9]{32,}"]))
    prohibited_names = {"salary-v1.json", "auth.json", ".env", "cookies", "cookies.sqlite"}
    checked = 0
    for name, data in paths:
        base = Path(name).name.lower()
        if base in prohibited_names or base.endswith(".log") or base.startswith("salary-before-"):
            raise RuntimeError(label + " contains runtime/private file: " + name)
        if any(needle in data for needle in local_needles) or suspicious.search(data):
            raise RuntimeError(label + " privacy/path scan failed: " + name)
        checked += 1
    return checked


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package-cache", default=str(ROOT / "work/release-packages"))
    parser.add_argument("--derived-data", default=str(ROOT / "work/release-build"))
    parser.add_argument("--output", help="New output directory below work/ (never overwritten)")
    args = parser.parse_args()
    commit = clean_commit()
    output = in_work(args.output or ROOT / "work" / ("release-v" + VERSION + "-" + commit[:12]))
    derived = in_work(args.derived_data)
    cache = in_work(args.package_cache)
    output.mkdir(parents=True, exist_ok=False)
    derived.mkdir(parents=True, exist_ok=True)
    cache.mkdir(parents=True, exist_ok=True)
    log = output / "build.log"
    mapped = shlex.quote(str(ROOT) + "=/src/salary-island")
    command = ["xcodebuild", "-project", "boringNotch.xcodeproj", "-scheme", "boringNotch",
               "-configuration", "Release", "-derivedDataPath", str(derived),
               "-clonedSourcePackagesDirPath", str(cache), "-disableAutomaticPackageResolution",
               "CODE_SIGNING_ALLOWED=NO", "SWIFT_SERIALIZE_DEBUGGING_OPTIONS=NO",
               "OTHER_SWIFT_FLAGS=$(inherited) -file-prefix-map " + mapped + " -debug-prefix-map " + mapped,
               "OTHER_CFLAGS=$(inherited) -ffile-prefix-map=" + mapped + " -fdebug-prefix-map=" + mapped,
               "build"]
    print("Building Release from " + commit, flush=True)
    with log.open("wb") as file:
        run(*command, stdout=file, stderr=subprocess.STDOUT)
    if clean_commit() != commit:
        raise RuntimeError("Source changed during build; discard this output")
    app = derived / "Build/Products/Release/薪动日常.app"
    xpc = app / "Contents/XPCServices/BoringNotchXPCHelper.xpc"
    main_binary = verify_info(app, BUNDLE)
    xpc_binary = verify_info(xpc, XPC_BUNDLE)
    architectures = run("lipo", "-archs", main_binary, capture=True).strip()
    if architectures != "arm64" or run("lipo", "-archs", xpc_binary, capture=True).strip() != "arm64":
        raise RuntimeError("This release is intended for Apple Silicon only")
    for binary in [main_binary, xpc_binary]:
        run("xcrun", "strip", "-S", binary)
    # Re-sign bundled frameworks inside-out, retaining their existing entitlements.
    # No certificate/keychain identity is looked up: '-' explicitly means ad-hoc.
    for framework in sorted((app / "Contents/Frameworks").glob("*.framework")):
        run("codesign", "--force", "--deep", "--sign", "-", "--preserve-metadata=entitlements", framework)
    xpc_entitlements_path = ROOT / "BoringNotchXPCHelper/BoringNotchXPCHelper.entitlements"
    with xpc_entitlements_path.open("rb") as file:
        xpc_entitlements = plistlib.load(file)
    run("codesign", "--force", "--sign", "-", "--entitlements", xpc_entitlements_path, xpc)
    source_entitlements = (ROOT / "boringNotch/boringNotch.entitlements").read_text()
    main_entitlements = plistlib.loads(source_entitlements.replace("$(PRODUCT_BUNDLE_IDENTIFIER)", BUNDLE).encode())
    if main_entitlements.get("com.apple.security.app-sandbox") is not True:
        raise RuntimeError("Main App Sandbox must remain enabled")
    with tempfile.TemporaryDirectory(prefix="salary-release-sign-") as temporary:
        path = Path(temporary) / "app.entitlements"
        path.write_bytes(plistlib.dumps(main_entitlements))
        run("codesign", "--force", "--sign", "-", "--entitlements", path, app)
    verify_entitlements(app, main_entitlements)
    verify_entitlements(xpc, xpc_entitlements)
    components = [app] + sorted(p for p in app.rglob("*") if not p.is_symlink() and p.suffix in {".app", ".xpc", ".framework"} and p.is_dir())
    for component in components:
        run("codesign", "--verify", "--deep", "--strict", component)
        signature = subprocess.run(["codesign", "-dv", str(component)], check=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE).stderr
        if b"Signature=adhoc" not in signature:
            raise RuntimeError("Nested component is not ad-hoc signed: " + component.name)
    product_count = scan_files(((str(p.relative_to(app)), p.read_bytes()) for p in app.rglob("*")
                                if p.is_file() and not p.is_symlink()), "App")
    app_zip = output / ("SalaryDaily-v" + VERSION + "-macOS.zip")
    source_zip = output / ("SalaryDaily-v" + VERSION + "-source.zip")
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, app_zip)
    run("git", "archive", "--format=zip", "--prefix=salary-island-v" + VERSION + "/",
        "--output=" + str(source_zip), commit)
    with zipfile.ZipFile(source_zip) as archive:
        source_count = scan_files(((entry.filename, archive.read(entry)) for entry in archive.infolist()
                                   if not entry.is_dir()), "Source archive")
        if any("/work/" in name or "/.git/" in name for name in archive.namelist()):
            raise RuntimeError("Generated or private repository state in source archive")
    # Verify the distributable, not only the pre-ZIP build directory. No launch.
    with tempfile.TemporaryDirectory(prefix="salary-release-verify-") as temporary:
        run("ditto", "-x", "-k", app_zip, temporary)
        extracted = Path(temporary) / app.name
        verify_info(extracted, BUNDLE)
        run("codesign", "--verify", "--deep", "--strict", extracted)
        verify_entitlements(extracted, main_entitlements)
    if clean_commit() != commit:
        raise RuntimeError("Source changed during packaging; discard this output")
    assets = [{"name": p.name, "bytes": p.stat().st_size,
               "sha256": hashlib.sha256(p.read_bytes()).hexdigest()} for p in [app_zip, source_zip]]
    (output / "SHA256SUMS.txt").write_text("".join(item["sha256"] + "  " + item["name"] + "\n" for item in assets))
    manifest = {"version": VERSION, "build": BUILD, "commit": commit,
                "bundleIdentifier": BUNDLE, "xpcBundleIdentifier": XPC_BUNDLE,
                "architecture": architectures, "xcode": run("xcodebuild", "-version", capture=True).strip(),
                "signature": "ad-hoc", "notarized": False, "aiScope": "offline fixtures and explicitly labeled demo only; no live accounts",
                "mainSandbox": True, "xpcSandbox": xpc_entitlements.get("com.apple.security.app-sandbox"),
                "verifiedCodeComponents": len(components), "appFilesScanned": product_count,
                "sourceFilesScanned": source_count, "pathAndCredentialPatternScan": "passed",
                "launchedOrInstalled": False, "published": False, "assets": assets}
    (output / "BUILD-MANIFEST.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(manifest, ensure_ascii=False, indent=2))
    print("Output: " + str(output))
    print("Nothing launched, installed, pushed, tagged or uploaded.")


if __name__ == "__main__":
    main()
