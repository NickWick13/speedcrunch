#!/bin/bash
# Usage: notarize-macos.sh FILE.dmg|FILE.zip
# Run manually after signing. Uses the existing DeveloperID Keychain profile.
# DMGs receive their own ticket. ZIPs are rebuilt with a stapled SpeedCrunch.app.

if [ "$#" -ne 1 ]; then
  printf 'Usage: %s FILE.dmg|FILE.zip\n' "${0##*/}" >&2
  exit 1
fi

notary_dir="$(cd "$(dirname "$1")" && pwd)" || exit
notary_file="$notary_dir/$(basename "$1")"
[ -f "$notary_file" ] || { printf 'File not found: %s\n' "$notary_file" >&2; exit 1; }
notary_work="$(mktemp -d)" || exit
notary_repacked=
trap 'rm -rf "$notary_work"; [ -z "$notary_repacked" ] || rm -f "$notary_repacked"' EXIT

notary_upload="$notary_file"
notary_target="$notary_file"
case "$notary_file" in
  *.dmg) ;;
  *.zip)
    ditto -x -k "$notary_file" "$notary_work/payload" || exit
    notary_target="$(find "$notary_work/payload" -type d -name SpeedCrunch.app -prune)" || exit
    [ -d "$notary_target" ] || { printf 'Expected exactly one SpeedCrunch.app\n' >&2; exit 1; }
    notary_upload="$notary_work/submit.zip"
    ditto -c -k --keepParent "$notary_target" "$notary_upload" || exit
    ;;
  *) printf 'Choose a DMG or ZIP file\n' >&2; exit 1 ;;
esac

notary_result="$notary_file.notary-result.json"
notary_rc=0
printf 'Submitting and waiting for Apple: %s\n' "$notary_file"
xcrun notarytool submit "$notary_upload" --keychain-profile DeveloperID \
  --wait --output-format json > "$notary_result" || notary_rc=$?
notary_decision="$(plutil -extract status raw -o - "$notary_result" 2>/dev/null)" || notary_decision=
notary_id="$(plutil -extract id raw -o - "$notary_result" 2>/dev/null)" || notary_id=

if [ -n "$notary_id" ]; then
  xcrun notarytool log "$notary_id" --keychain-profile DeveloperID \
    "$notary_work/log.json" && cp "$notary_work/log.json" "$notary_file.notary-log.json" \
    || printf 'Notarization log unavailable. See the submission result.\n' >&2
fi
if [ "$notary_rc" -ne 0 ] || [ "$notary_decision" != Accepted ]; then
  printf 'Notarization failed: %s\n' "${notary_decision:-unknown}" >&2
  cat "$notary_result"
  [ ! -f "$notary_work/log.json" ] || cat "$notary_work/log.json"
  exit 1
fi

xcrun stapler staple "$notary_target" || exit
xcrun stapler validate "$notary_target" || exit
codesign --verify --deep --strict "$notary_target" || exit

case "$notary_file" in
  *.zip)
    notary_repacked="$(mktemp "$notary_file.stapled.XXXXXX")" || exit
    ditto -c -k "$notary_work/payload" "$notary_repacked" || exit
    chmod "$(stat -f '%Lp' "$notary_file")" "$notary_repacked" || exit
    mv -f "$notary_repacked" "$notary_file" || exit
    notary_repacked=
    ;;
esac
printf 'Notarized and stapled: %s\n' "$notary_file"
