"""Build an isolated native notification proof app; restore temporary source instrumentation."""
from pathlib import Path
import hashlib
import json
import plistlib
import shutil
import subprocess
import sys

root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path.cwd()
artifacts = Path(__file__).resolve().parent
output = root / ".build/homebrew-notification-proof"
output.mkdir(parents=True, exist_ok=True)
entry = root / "Sources/CodexBar/CodexbarApp.swift"
helper = root / "Sources/CodexBar/HomebrewUpdateAppProof.swift"
original = entry.read_bytes()
assert not helper.exists(), "Do not overwrite existing work"
production_paths = [
    "Sources/CodexBar/AppNotifications.swift",
    "Sources/CodexBar/HomebrewUpdateNotifier.swift",
    "Sources/CodexBar/HomebrewUpdater.swift",
    "Sources/CodexBar/CodexbarApp.swift",
    "Sources/CodexBar/SettingsWindowController.swift",
    "Sources/CodexBar/PreferencesAboutPane.swift",
]
source_hashes = {
    path: hashlib.sha256((root / path).read_bytes()).hexdigest() for path in production_paths
}
try:
    shutil.copyfile(artifacts / helper.name, helper)
    anchor = "        #if DEBUG\n        if MenuBarLayoutNativeProof.runIfRequested() {"
    factory = "private func makeUpdaterController() -> UpdaterProviding {\n    let bundleURL"
    text = original.decode()
    assert text.count(anchor) == 1 and text.count(factory) == 1
    text = text.replace(anchor,
        "        #if DEBUG\n        if HomebrewUpdateAppProof.runIfRequested() { return }\n"
        "        if MenuBarLayoutNativeProof.runIfRequested() {", 1)
    text = text.replace(factory,
        "private func makeUpdaterController() -> UpdaterProviding {\n"
        "    #if DEBUG\n"
        "    if HomebrewUpdateAppProof.isRequested { return HomebrewUpdateAppProof.makeUpdater() }\n"
        "    #endif\n    let bundleURL", 1)
    entry.write_text(text)
    subprocess.run(["swift", "build", "--product", "CodexBar"], cwd=root, check=True)
    binary_dir = Path(subprocess.check_output(
        ["swift", "build", "--show-bin-path"], cwd=root, text=True).strip())
    bundle = output / "CodexBarUpdateProof.app"
    executable = bundle / "Contents/MacOS/CodexBarUpdateProof"
    executable.parent.mkdir(parents=True, exist_ok=True)
    resources = bundle / "Contents/Resources"
    resources.mkdir(parents=True, exist_ok=True)
    frameworks = bundle / "Contents/Frameworks"
    frameworks.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(binary_dir / "CodexBar", executable)
    executable.chmod(0o755)
    for resource in binary_dir.glob("*.bundle"):
        subprocess.run(["ditto", str(resource), str(resources / resource.name)], check=True)
    sparkle = next((root / ".build/artifacts").rglob("Sparkle.framework"))
    subprocess.run(["ditto", str(sparkle), str(frameworks / "Sparkle.framework")], check=True)
    if (root / "Icon.icns").exists():
        shutil.copyfile(root / "Icon.icns", resources / "Icon.icns")
    with (bundle / "Contents/Info.plist").open("wb") as file:
        plistlib.dump({
            "CFBundleName": "CodexBar Update Proof",
            "CFBundleDisplayName": "CodexBar Update Proof",
            "CFBundleIdentifier": "local.codexbar.homebrew-update-proof",
            "CFBundleExecutable": executable.name,
            "CFBundlePackageType": "APPL",
            "CFBundleIconFile": "Icon",
            "CFBundleVersion": "1",
            "CFBundleShortVersionString": "99.0.0",
            "NSHighResolutionCapable": True,
            "LSUIElement": False,
            "CodexBarHomebrewUpdateProof": True,
            "CodexBarTeamID": "PROOFFIXTURE",
        }, file)
    subprocess.run(["install_name_tool", "-add_rpath", "@executable_path/../Frameworks", str(executable)], check=True)
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(bundle)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
    receipt = {
        "kind": "full CodexBar executable with documentation-only native notification fixture",
        "source_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
        "executable_sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
        "fixture_source_sha256": hashlib.sha256(helper.read_bytes()).hexdigest(),
        "original_entry_source_sha256": hashlib.sha256(original).hexdigest(),
        "instrumented_entry_source_sha256": hashlib.sha256(entry.read_bytes()).hexdigest(),
        "production_source_sha256": source_hashes,
        "bundle_id": "local.codexbar.homebrew-update-proof",
        "signing": "ad-hoc; codesign --verify --deep --strict passed",
        "fixture_versions": ["99.0.0", "99.0.1", "99.0.2"],
        "credential_access": False,
        "live_provider_requests": False,
        "actual_homebrew_upgrade": False,
        "instrumentation": [
            "temporary DEBUG entry guard before normal provider startup",
            "temporary DEBUG updater factory selecting synthetic cask/version dependencies",
            "production AppDelegate receives application lifecycle through fixture wrapper",
            "three-second delayed production settings configuration for pending cold-click route",
        ],
        "notification_sender": "HomebrewUpdateNotifier.Dependencies.live -> AppNotifications.shared -> UNUserNotificationCenter",
        "notification_delegate": "AppNotifications.shared; no callback injection",
        "settings_route": "AppDelegate -> SettingsWindowController -> PreferencesView -> AboutPane",
    }
    (output / "build-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
finally:
    entry.write_bytes(original)
    helper.unlink(missing_ok=True)
