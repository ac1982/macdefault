# Signed releases

The release workflow reuses haul’s Developer ID signing and notarization setup:
team `89G3DBC6CS`, `Developer ID Application: Qi Jiang (89G3DBC6CS)` and
`Developer ID Installer: Qi Jiang (89G3DBC6CS)`. Certificates belong to the team;
macdefault uses its own signing and package identifier `com.ac1982.macdefault`.

The following encrypted repository secrets are required:

- `MACOS_APPLICATION_P12_BASE64`
- `MACOS_INSTALLER_P12_BASE64`
- `MACOS_CERTIFICATE_PASSWORD`
- `APPLE_API_KEY_P8`
- `APPLE_API_KEY_ID`
- `APPLE_API_ISSUER_ID`

The maintainer’s existing haul signing materials live outside the repository at
`~/Library/Application Support/haul-signing/89G3DBC6CS/`. Never commit or log
private keys or passwords. CI imports certificates into a temporary keychain and
cleans up the keychain and decoded secrets on success or failure.

Update the source version and its CLI test, commit, then push an immutable numeric
tag such as `1.0.0`. GitHub Actions tests and builds the universal Swift executable,
signs it, builds a signed package installing to `/usr/local/bin`, and submits it
to Apple. Publication requires Accepted notarization, successful stapling and
staple validation, and Gatekeeper assessment. Archives contain the same signed
executable as the package. Checksums are generated after signing and stapling.

Signing or notarization failures stop publication. The workflow can be rerun at
the tag after addressing an infrastructure issue without moving the tag. Apple
signing does not suppress macOS default-application consent prompts.
