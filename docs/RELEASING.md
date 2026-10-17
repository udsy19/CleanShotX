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

## Keep the signing identity stable

Releases are signed with the "Super Screenshot Local Signing" identity in `.signing/superscreenshot.keychain-db`
(created once by `scripts/signing-setup.sh`, never committed). macOS ties Screen Recording and Accessibility
permissions to the app's code signature: **if the identity changes, every user has to grant permissions again.**
Back up `.signing/superscreenshot.keychain-db` somewhere safe and reuse it on any machine that builds releases.
The identity was created anew for 1.2.0, when the bundle id changed with the rename, so that release asks everyone
for Screen Recording permission once anyway.

Moving to an Apple Developer ID later is a deliberate one-time change — announce it in the release notes, because
users will need to re-enable Screen Recording once (remove and re-add Super Screenshot in System Settings if capture fails).
