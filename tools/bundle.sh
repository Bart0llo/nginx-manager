#!/bin/bash
# ==========================================================
# Builds the single-file nginx-manager script that install.sh downloads:
# nginx-site.sh with its lib/*.sh modules inlined in source order.
#
#   tools/bundle.sh [output]      default: dist/nginx-site.sh
# ==========================================================
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$root/dist/nginx-site.sh}"
tmp="$out.tmp"

mkdir -p "$(dirname "$out")"

in_block=0
while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
        "# @bundle-begin") in_block=1 ;;
        "# @bundle-end") in_block=0 ;;
        *)
            if ((in_block)); then
                if [[ "$line" =~ ^source\ \"\$NM_LIB_DIR/([a-z_]+\.sh)\"$ ]]; then
                    echo
                    # Drop the module's shebang line.
                    tail -n +2 "$root/lib/${BASH_REMATCH[1]}"
                fi
            else
                printf '%s\n' "$line"
            fi
            ;;
    esac
done < "$root/nginx-site.sh" > "$tmp"

if ((in_block)) || grep -q 'NM_LIB_DIR' "$tmp"; then
    echo "bundle: unbalanced @bundle markers or unresolved module reference" >&2
    rm -f "$tmp"
    exit 1
fi

bash -n "$tmp"
chmod 755 "$tmp"
mv "$tmp" "$out"
echo "$out"
