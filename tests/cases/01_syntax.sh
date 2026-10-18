#!/bin/bash
# bash -n on every shell script, using the container's Debian bash.

t_bash_syntax_all_scripts() {
    local f
    while IFS= read -r f; do
        if bash -n "$f" 2>/dev/null; then pass "bash -n $f"; else fail "bash -n $f"; fi
    done < <(find /src -name '*.sh' -not -path '/src/tests/.out/*' -not -path '/src/.git/*' | sort)
}
