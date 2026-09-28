#!/bin/bash
# Sign a Swift binary, create a signed installer, and require Apple's acceptance.
set -euo pipefail

if [[ $# -ne 3 || $(uname -s) != Darwin ]]; then
  echo 'Usage on macOS: scripts/sign-macos.sh <binary> <output.pkg> <version>' >&2
  exit 2
fi

binary=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
mkdir -p "$(dirname "$2")"
package=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
version=${3#v}
version_pattern='^([0-9]+)\.([0-9]+)\.([0-9]+)([-+][0-9A-Za-z.+-]+)?$'
if [[ ! $version =~ $version_pattern ]]; then
  echo 'Package version must use major.minor.patch, with an optional suffix' >&2
  exit 2
fi
package_version="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
[[ -f "$binary" && -x "$binary" ]] || { echo 'Executable not found' >&2; exit 2; }
architecture=$(lipo -archs "$binary")
case "$architecture" in
  arm64|x86_64) ;;
  "arm64 x86_64"|"x86_64 arm64") architecture="arm64,x86_64" ;;
  *) echo 'Expected a macOS arm64, x86_64, or universal executable' >&2; exit 2 ;;
esac
for name in MACOS_APPLICATION_P12_BASE64 MACOS_INSTALLER_P12_BASE64 \
  MACOS_CERTIFICATE_PASSWORD APPLE_API_KEY_P8 APPLE_API_KEY_ID APPLE_API_ISSUER_ID; do
  if [[ -z ${!name:-} ]]; then
    echo "Missing release secret: $name" >&2
    exit 1
  fi
done

umask 077
signing_tmp=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/macdefault-signing.XXXXXX")
keychain="$signing_tmp/signing.keychain-db"
# search_list sets the user's keychain search list to the given keychains followed by the saved original list.
search_list() {
  python3 - "$signing_tmp/search-list.txt" "$@" <<'PY'
import pathlib, shlex, subprocess, sys
paths = shlex.split(pathlib.Path(sys.argv[1]).read_text())
subprocess.run(['security', 'list-keychains', '-d', 'user', '-s', *sys.argv[2:], *paths], check=True)
PY
}
cleanup() {
  if [[ -f "$signing_tmp/search-list.txt" ]]; then
    search_list >/dev/null 2>&1 || true
  fi
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  rm -rf "$signing_tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf '%s' "$MACOS_APPLICATION_P12_BASE64" | base64 -D > "$signing_tmp/application.p12"
printf '%s' "$MACOS_INSTALLER_P12_BASE64" | base64 -D > "$signing_tmp/installer.p12"
printf '%s' "$APPLE_API_KEY_P8" > "$signing_tmp/notary.p8"
unset MACOS_APPLICATION_P12_BASE64 MACOS_INSTALLER_P12_BASE64 APPLE_API_KEY_P8
keychain_password=$(openssl rand -hex 32)
# codesign and productbuild find the private keys and the intermediate certificate only through the search list,
# so the keychain joins it while signing; cleanup restores the original list.
security list-keychains -d user > "$signing_tmp/search-list.txt"
security create-keychain -p "$keychain_password" "$keychain"
search_list "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
for name in application installer; do
  security import "$signing_tmp/$name.p12" -k "$keychain" \
    -P "$MACOS_CERTIFICATE_PASSWORD" -T /usr/bin/codesign -T /usr/bin/productbuild
done
unset MACOS_CERTIFICATE_PASSWORD
# Public intermediate certificate; macOS supplies the trusted Apple root.
curl --fail --silent --show-error --location --retry 5 --retry-all-errors \
  https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer \
  -o "$signing_tmp/DeveloperIDG2CA.cer"
if [[ $(shasum -a 256 "$signing_tmp/DeveloperIDG2CA.cer" | cut -d ' ' -f 1) != \
      f16cd3c54c7f83cea4bf1a3e6a0819c8aaa8e4a1528fd144715f350643d2df3a ]]; then
  echo 'Unexpected Developer ID G2 intermediate certificate' >&2
  exit 1
fi
security import "$signing_tmp/DeveloperIDG2CA.cer" -k "$keychain"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
  -k "$keychain_password" "$keychain" >/dev/null
unset keychain_password
identities=$(security find-identity -v "$keychain")
application_identity=$(printf '%s\n' "$identities" | awk -F '"' '/Developer ID Application:/ {print $2}')
installer_identity=$(printf '%s\n' "$identities" | awk -F '"' '/Developer ID Installer:/ {print $2}')
# Require the configured team and exactly one identity of each kind.
if [[ "$application_identity" != 'Developer ID Application: Qi Jiang (89G3DBC6CS)' ||
      "$installer_identity" != 'Developer ID Installer: Qi Jiang (89G3DBC6CS)' ]]; then
  echo 'Expected macdefault Developer ID identities were not found' >&2
  exit 1
fi
codesign --force --sign "$application_identity" --keychain "$keychain" \
  --options runtime --timestamp --identifier com.ac1982.macdefault "$binary"
codesign --verify --strict --verbose=2 "$binary"

mkdir -p "$signing_tmp/root"
cp "$binary" "$signing_tmp/root/macdefault"
# umask protects secrets; installed executables must still be usable by all users.
chmod 755 "$signing_tmp/root" "$signing_tmp/root/macdefault"
pkgbuild --root "$signing_tmp/root" --install-location /usr/local/bin \
  --identifier com.ac1982.macdefault --version "$package_version" --ownership recommended \
  "$signing_tmp/component.pkg"
productbuild --synthesize --package "$signing_tmp/component.pkg" "$signing_tmp/Distribution.xml"
python3 - "$signing_tmp/Distribution.xml" "$architecture" <<'PY'
import sys, xml.etree.ElementTree as ET
path, arch = sys.argv[1:]
tree = ET.parse(path)
root = tree.getroot()
options = root.find('options')
if options is None:
    options = ET.SubElement(root, 'options')
options.set('hostArchitectures', arch)
options.set('customize', 'never')
title = root.find('title')
if title is None:
    title = ET.SubElement(root, 'title')
title.text = 'macdefault'
tree.write(path, encoding='utf-8', xml_declaration=True)
PY
productbuild --distribution "$signing_tmp/Distribution.xml" --package-path "$signing_tmp" \
  --sign "$installer_identity" --keychain "$keychain" "$package"
pkgutil --check-signature "$package"

notary_args=(--key "$signing_tmp/notary.p8" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID")
# Preserve the submission ID in CI logs even if Apple's queue exceeds the timeout.
if ! xcrun notarytool submit "$package" "${notary_args[@]}" \
  --wait --timeout 20m --output-format json > "$signing_tmp/notary.json"; then
  cat "$signing_tmp/notary.json"
  echo 'Notarization did not finish successfully; nothing will be published' >&2
  exit 1
fi
cat "$signing_tmp/notary.json"
if ! python3 - "$signing_tmp/notary.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
sys.exit(0 if result.get('status') == 'Accepted' else 1)
PY
then
  echo 'Apple has not accepted the package; nothing will be published' >&2
  exit 1
fi
xcrun stapler staple "$package"
xcrun stapler validate "$package"
spctl --assess --type install --verbose=2 "$package"
chmod 644 "$package"
