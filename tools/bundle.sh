#!/bin/bash
# ==========================================================
# Builds the single-file nginx-manager script that install.sh installs:
# nginx-site.sh with its lib/*.sh modules inlined in source order.
#
#   tools/bundle.sh [--version V] [output]   default: dist/nginx-site.sh
#
# --version stamps NM_VERSION (default "dev", as in a checkout). Each
# inlined module is preceded by "# @nm-module <file>" and the last line
# lists them all ("# @nm-bundle-end modules=..."), so install.sh can tell
# a complete bundle from a truncated file or the modular entry point.
# Only the lib/ modules nginx-site.sh sources are read; nothing else in
# the checkout ends up in the bundle. The output is reproducible.
# ==========================================================
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
version=dev
if [[ "${1:-}" == --version ]]; then
    version="${2:-}"
    shift 2 || true
fi
if [[ ! "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$ ]]; then
    echo "bundle: invalid version '$version'" >&2
    exit 1
fi
out="${1:-$root/dist/nginx-site.sh}"
tmp="$out.tmp"
trap 'rm -f "$tmp"' EXIT

mkdir -p "$(dirname "$out")"

in_block=0 stamped=0 modules=()
{
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            "# @bundle-begin") in_block=1 ;;
            "# @bundle-end") in_block=0 ;;
            'NM_VERSION="dev"')
                printf 'NM_VERSION="%s"\n' "$version"
                stamped=$((stamped + 1))
                ;;
            *)
                if ((in_block)); then
                    if [[ "$line" =~ ^source\ \"\$NM_LIB_DIR/([a-z_]+\.sh)\"$ ]]; then
                        module="${BASH_REMATCH[1]}"
                        if [[ ! -f "$root/lib/$module" ]]; then
                            echo "bundle: lib/$module not found" >&2
                            exit 1
                        fi
                        echo
                        echo "# @nm-module $module"
                        # Drop the module's shebang line.
                        tail -n +2 "$root/lib/$module"
                        modules+=("$module")
                    fi
                else
                    printf '%s\n' "$line"
                fi
                ;;
        esac
    done < "$root/nginx-site.sh"
    printf '# @nm-bundle-end modules=%s\n' "${modules[*]}"
} > "$tmp"

if ((in_block)) || grep -q 'NM_LIB_DIR' "$tmp"; then
    echo "bundle: unbalanced @bundle markers or unresolved module reference" >&2
    exit 1
fi
if ((stamped != 1 || ${#modules[@]} == 0)); then
    echo "bundle: expected one NM_VERSION=\"dev\" line and at least one module" >&2
    exit 1
fi

bash -n "$tmp"
chmod 755 "$tmp"
mv "$tmp" "$out"
echo "$out"
