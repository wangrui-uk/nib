#!/bin/sh
# Publishes a built release: creates the GitHub release vX.Y.Z (notes from CHANGELOG.md), uploads dist/Nib-X.Y.Z.dmg,
# and, if Sparkle's sign_update tool is available, adds the update to docs/appcast.xml (commit and push it afterwards).
#   ./publish.sh [VERSION]        (default: the version in build.sh; run by `./release.sh --publish`)
# Needs: GH_TOKEN or GITHUB_TOKEN (repo access), GITHUB_REPO=owner/name (env or release.local.env), and the tag's
# commit pushed. For the appcast: SPARKLE_BIN (folder with sign_update; default: the one SwiftPM downloads with Sparkle) and the EdDSA
# private key in your login Keychain (created once with Sparkle's generate_keys). Never prints the token.
set -eu
cd "$(dirname "$0")"
[ -f release.local.env ] && . ./release.local.env
fail() { echo "publish: $*" >&2; exit 1; }
VERSION=${1:-$(sed -n 's/^VERSION=\${VERSION:-\(.*\)}$/\1/p' build.sh)}
BUILD=$(sed -n 's/^BUILD_NUMBER=\${BUILD_NUMBER:-\(.*\)}$/\1/p' build.sh)
TOKEN=${GH_TOKEN:-${GITHUB_TOKEN:-}}
[ -n "$TOKEN" ] || fail "set GH_TOKEN or GITHUB_TOKEN"
[ -n "${GITHUB_REPO:-}" ] || fail "set GITHUB_REPO=owner/name"
DMG="dist/Nib-$VERSION.dmg"
[ -f "$DMG" ] || fail "$DMG not found (run ./release.sh first)"
TAG="v$VERSION"
API="https://api.github.com/repos/$GITHUB_REPO"
AUTH="Authorization: Bearer $TOKEN"
mkdir -p build

# Release notes: the "## X.Y.Z" section of CHANGELOG.md.
awk -v v="## $VERSION" '$0 == v {on=1; next} /^## / {if (on) exit} on' CHANGELOG.md > build/notes.md
[ -s build/notes.md ] || fail "no '## $VERSION' section in CHANGELOG.md"
printf '\n**Download:** `Nib-%s.dmg` below (signed with a Developer ID and notarised by Apple). Requires macOS 13 or later.\n' "$VERSION" >> build/notes.md

echo "== GitHub release $TAG"
SHA=$(git rev-parse "$TAG^{commit}" 2>/dev/null || git rev-parse HEAD)
python3 - "$TAG" "$SHA" build/notes.md > build/release.json <<'EOF'
import json, sys
tag, sha, notes = sys.argv[1], sys.argv[2], open(sys.argv[3]).read()
print(json.dumps({"tag_name": tag, "target_commitish": sha, "name": "Nib " + tag[1:], "body": notes, "draft": False, "prerelease": False}))
EOF
code=$(curl -sS -o build/release-out.json -w '%{http_code}' -X POST -H "$AUTH" -H "Accept: application/vnd.github+json" "$API/releases" --data @build/release.json)
if [ "$code" = 422 ]; then
  code=$(curl -sS -o build/release-out.json -w '%{http_code}' -H "$AUTH" "$API/releases/tags/$TAG")
fi
[ "$code" = 201 ] || [ "$code" = 200 ] || { cat build/release-out.json >&2; fail "creating the release failed (HTTP $code)"; }
ID=$(python3 -c 'import json; print(json.load(open("build/release-out.json"))["id"])')
URL=$(python3 -c 'import json; print(json.load(open("build/release-out.json"))["html_url"])')
NAME="Nib-$VERSION.dmg"
EXISTING=$(python3 -c 'import json,sys; print(next((a["id"] for a in json.load(open("build/release-out.json")).get("assets", []) if a["name"] == sys.argv[1]), ""))' "$NAME")
[ -n "$EXISTING" ] && curl -sS -o /dev/null -X DELETE -H "$AUTH" "$API/releases/assets/$EXISTING"
code=$(curl -sS -o build/asset-out.json -w '%{http_code}' -X POST -H "$AUTH" -H "Content-Type: application/x-apple-diskimage" \
  --data-binary @"$DMG" "https://uploads.github.com/repos/$GITHUB_REPO/releases/$ID/assets?name=$NAME")
[ "$code" = 201 ] || { cat build/asset-out.json >&2; fail "uploading the DMG failed (HTTP $code)"; }
DL=$(python3 -c 'import json; print(json.load(open("build/asset-out.json"))["browser_download_url"])')
echo "released: $URL"
echo "download: $DL"

# Sparkle appcast (only for builds that contain Sparkle).
SPARKLE_BIN=${SPARKLE_BIN:-.build/artifacts/sparkle/Sparkle/bin}
if [ -x "$SPARKLE_BIN/sign_update" ] && [ -f docs/appcast.xml ]; then
  echo "== appcast"
  SIG=$("$SPARKLE_BIN/sign_update" "$DMG")   # sparkle:edSignature="…" length="…"
  python3 - "$VERSION" "$BUILD" "$DL" "$SIG" build/notes.md docs/appcast.xml <<'EOF'
import sys, html, re, email.utils
version, build, url, sig, notes_path, appcast = sys.argv[1:7]
notes = open(notes_path).read().split("\n**Download:**")[0].strip()
items = "".join(f"<li>{html.escape(l[2:])}</li>" for l in notes.splitlines() if l.startswith("- "))
items = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", items)
item = f"""    <item>
      <title>Nib {version}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<ul>{items}</ul>]]></description>
      <enclosure url="{url}" {sig} type="application/octet-stream"/>
    </item>
"""
s = open(appcast).read()
s = re.sub(r"    <item>\s*<title>Nib " + re.escape(version) + r"</title>.*?</item>\n", "", s, flags=re.S)
s = s.replace("    <!-- items -->\n", "    <!-- items -->\n" + item, 1)
open(appcast, "w").write(s)
print("appcast: added Nib", version)
EOF
  echo "Now commit and push docs/appcast.xml so installed copies see the update."
fi
