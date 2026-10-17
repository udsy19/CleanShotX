# Releasing

```bash
# 1. Add the release notes under a new "## [x.y.z]" heading in CHANGELOG.md and commit.
# 2. Build, tag and publish:
./scripts/release.sh x.y.z
```

`release.sh` stamps the version and build number into `Resources/Info.plist`, commits that as "Release x.y.z", builds the universal app and DMG, creates a signed tag
and publishes a GitHub release with two assets: `SuperScreenshot-x.y.z.dmg` and a stable `SuperScreenshot.dmg`. The
one-line installer and the website always download `releases/latest/download/SuperScreenshot.dmg`, so they pick up
new releases automatically.

## Automatic updates depend on the release format

Installed copies poll `https://api.github.com/repos/udsy19/super-screenshot/releases/latest` (UpdateKit) and install a
release only when all of this holds — `release.sh` takes care of the first three:

1. **The tag matches the app.** `v1.3.0` must equal the bundle's `CFBundleShortVersionString`, and it must be newer
   than the installed version. Drafts and pre-releases never appear at `releases/latest`.
2. **The stable asset name.** An asset named exactly `SuperScreenshot.dmg` (or `SuperScreenshot-<version>.dmg`) with
   `SuperScreenshot.app` at the top level of the volume.
3. **The checksum line.** The release notes contain ``SHA-256 (SuperScreenshot.dmg): `<64 hex digits>` `` exactly as
   `release.sh` writes it. A release without the line, or whose DMG doesn't match it, is skipped — keep the line if you
   edit the notes on GitHub, and update it if you ever replace the asset.
4. **The same signing identity.** The new app must pass a strict code-signature check and satisfy the running app's
   designated requirement (`identifier "com.udsy.superscreenshot" and certificate leaf = H"…"`), with the same
   bundle identifier. See below.

Every failure is silent on users' Macs (logged under the `update` category, retried at the next check), so check a
release with `log show --predicate 'subsystem == "com.udsy.superscreenshot" AND category == "update"' --last 1h` on a
machine running the previous version. Debug builds can read a local feed from the `SUPERSCREENSHOT_UPDATE_FEED`
environment variable; release builds always use GitHub. `swift run SuperScreenshotSelfTest` runs the whole
download → verify → stage → swap path against `build/SuperScreenshot.app` on a loopback server.

## Keep the signing identity stable

Releases are signed with the "Super Screenshot Local Signing" identity in `.signing/superscreenshot.keychain-db`
(created once by `scripts/signing-setup.sh`, never committed). macOS ties Screen Recording and Accessibility
permissions to the app's code signature: **if the identity changes, every user has to grant permissions again, and
installed copies refuse the new release as an update** — users would have to download it by hand.
Back up `.signing/superscreenshot.keychain-db` somewhere safe and reuse it on any machine that builds releases.
The identity was created anew for 1.2.0, when the bundle id changed with the rename, so that release asks everyone
for Screen Recording permission once anyway.

Moving to an Apple Developer ID later is a deliberate one-time change — announce it in the release notes, because
users will need to re-enable Screen Recording once (remove and re-add Super Screenshot in System Settings if capture fails),
and automatic updates won't carry anyone across it: everyone installs that release manually.
