#!/bin/bash
# ==========================================================
# Test suite entry point.
#
#   tests/run.sh                 run every case
#   tests/run.sh 05 07           run cases whose file name starts with 05 / 07
#   NM_TEST_BUNDLE=1 tests/run.sh  run every case against the tools/bundle.sh output
#
# Each case file runs in its own disposable debian:stable container with
# networking disabled and the repository mounted read-only, so the host's
# nginx, certificates and /etc are never touched. Logs and captured output
# go to tests/.out/.
# ==========================================================
cd "$(dirname "$0")/.." || exit 1

IMAGE="nginx-manager-test:latest"
OUT="tests/.out"

command -v docker >/dev/null 2>&1 || { echo "docker is required to run the tests"; exit 1; }

echo "Syntax check (host bash):"
syntax_failed=0
while IFS= read -r f; do
    if bash -n "$f"; then echo "  ok   $f"; else echo "  FAIL $f"; syntax_failed=1; fi
done < <(find . -name '*.sh' -not -path './tests/.out/*' -not -path './.git/*' | sort)
echo

echo "Building test image..."
docker build -q -t "$IMAGE" tests/ >/dev/null || { echo "image build failed"; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"

# Docker on Windows needs a native path for bind mounts; stop MSYS/Cygwin
# from rewriting the container-side paths.
src="$PWD" out="$PWD/$OUT"
if command -v cygpath >/dev/null 2>&1; then
    src=$(cygpath -m "$src") out=$(cygpath -m "$out")
fi
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'

cases=()
if (($# == 0)); then
    cases=(tests/cases/*.sh)
else
    for prefix in "$@"; do cases+=(tests/cases/"$prefix"*.sh); done
fi

failed=0
for c in "${cases[@]}"; do
    [[ -f "$c" ]] || { echo "no such case: $c"; failed=1; continue; }
    docker run --rm --network none -e NM_TEST_BUNDLE \
        -v "$src:/src:ro" -v "$out:/out" \
        "$IMAGE" bash /src/tests/lib/runner.sh "/src/$c" || failed=1
done

echo
if ((failed || syntax_failed)); then
    echo "RESULT: FAILED (logs in $OUT/logs/)"
    exit 1
fi
echo "RESULT: all tests passed"
