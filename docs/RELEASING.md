# Releasing

```bash
# 1. Add the release notes under a new "## [x.y.z]" heading in CHANGELOG.md and commit.
# 2. Build, tag and publish:
./scripts/release.sh x.y.z
```

`release.sh` stamps the version and build number into `Resources/Info.plist`, commits that as "Release x.y.z", builds the universal app and DMG, creates a signed tag
and publishes a GitHub release with two assets: `Shotcraft-x.y.z.dmg` and a stable `Shotcraft.dmg`. The one-line
installer and the website always download `releases/latest/download/Shotcraft.dmg`, so they pick up new releases
automatically.

## Keep the signing identity stable

Releases are signed with the identity in `.signing/` (created once by `scripts/signing-setup.sh`, never committed).
macOS ties Screen Recording and Accessibility permissions to the app's code signature: **if the identity changes,
every user has to grant permissions again.** Back up `.signing/shotcraft.keychain-db` somewhere safe and reuse it on
any machine that builds releases.

Moving to an Apple Developer ID later is a deliberate one-time change — announce it in the release notes, because
users will need to re-enable Screen Recording once (remove and re-add Shotcraft in System Settings if capture fails).
