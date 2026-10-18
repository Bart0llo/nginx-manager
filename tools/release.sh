#!/bin/bash
# ==========================================================
# Builds the GitHub Release assets for one version:
#   nginx-site.sh   the bundle (tools/bundle.sh), NM_VERSION = <version>
#   install.sh      the installer, with <owner/repo> as its default repository
#   SHA256SUMS      sha256sum of both, in "sha256sum -c" format
#
#   tools/release.sh <version> <owner/repo> [output-dir]   default: dist/release
#
# <version> is the release tag, vMAJOR.MINOR.PATCH. The output directory
# must be new or empty. Nothing is tagged, uploaded or downloaded: the
# release workflow (.github/workflows/release.yml) publishes the files.
# ==========================================================
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:-}" repo="${2:-}" out="${3:-$root/dist/release}"

die() { echo "release: $*" >&2; exit 1; }

[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must look like v1.2.3 (got '$version')"
[[ "$repo" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]] || die "repository must be owner/name (got '$repo')"
if [[ -e "$out" && -n "$(ls -A "$out")" ]]; then
    die "$out is not empty"
fi
mkdir -p "$out"

bash "$root/tools/bundle.sh" --version "$version" "$out/nginx-site.sh" >/dev/null

[[ $(grep -cx 'NM_REPO_DEFAULT="[^"]*"' "$root/install.sh") == 1 ]] || die "install.sh: NM_REPO_DEFAULT line not found"
sed "s|^NM_REPO_DEFAULT=\"[^\"]*\"\$|NM_REPO_DEFAULT=\"$repo\"|" "$root/install.sh" > "$out/install.sh"
bash -n "$out/install.sh"
chmod 755 "$out/install.sh"

(cd "$out" && sha256sum nginx-site.sh install.sh > SHA256SUMS)
echo "$out"
