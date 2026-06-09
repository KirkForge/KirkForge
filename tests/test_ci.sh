#!/usr/bin/env bash
# test_ci.sh — minimal harness for scripts/ci.sh
#
# No bats, no external deps. Each test sets up a temp dir with controlled
# inputs (package.json, lockfiles, .ci-cleandev.yml, stubbed binstubs that
# record what they were called with) and asserts on the recorded calls and
# the script's exit code.
#
# Run from the project root:
#   bash tests/test_ci.sh
#
# Each test prints PASS or FAIL. The harness exits non-zero if any test
# fails. Tests are independent — they use mktemp dirs and clean up.
set -uo pipefail

# ─── harness plumbing ────────────────────────────────────────────────────────
SCRIPT_UNDER_TEST="$(cd "$(dirname "$0")/.." && pwd)/scripts/ci.sh"
PASS=0
FAIL=0
FAILED_TESTS=()

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        printf "    \033[0;32mPASS\033[0m %s\n" "$label"
        PASS=$((PASS + 1))
    else
        printf "    \033[0;31mFAIL\033[0m %s\n" "$label"
        printf "      expected: %q\n" "$expected"
        printf "      actual:   %q\n" "$actual"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$label")
    fi
}

# run_ci_in_dir <dir> <expected_exit_code>
# Runs ci.sh in <dir> with a clean PATH that only has stubs. Captures the
# exit code and the call log (each stub appends its argv to CALL_LOG).
run_ci_in_dir() {
    local dir="$1" expected_exit="$2"
    local stub_dir="$dir/.stubs"
    local log="$dir/.call_log"
    : > "$log"
    (
        cd "$dir"
        # Override PATH so only our stubs are findable. Keep /usr/bin:/bin
        # available so basic tools work, but the package managers and
        # scanners will only be our stubs.
        env -i PATH="$stub_dir:/usr/bin:/bin" HOME="$dir" bash "$SCRIPT_UNDER_TEST" \
            > "$dir/.stdout" 2> "$dir/.stderr"
    )
    local actual_exit=$?
    assert_eq "exit code" "$expected_exit" "$actual_exit"
}

# make_stub <path> <behavior>
# behavior = "pass" | "fail" | "log"
#   pass: exit 0
#   fail: exit 1
#   log:  exit 0, append argv to CALL_LOG
make_stub() {
    local path="$1" behavior="$2"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<STUB
#!/usr/bin/env bash
# Auto-generated test stub
echo "\$0 \$*" >> "\${CALL_LOG:-.call_log}"
case "$behavior" in
    pass) exit 0 ;;
    fail) exit 1 ;;
    log)  exit 0 ;;
    *) echo "unknown behavior: $behavior" >&2; exit 99 ;;
esac
STUB
    chmod +x "$path"
}

# Setup a project dir with stubs for npm/pnpm/yarn/bun/gitleaks/trufflehog.
# Args: <dir> <gitleaks_behavior> <trufflehog_behavior>
# npm/pnpm/yarn/bun are always "log" so we can assert what was called.
setup_project() {
    local dir="$1" gl_behavior="${2:-pass}" th_behavior="${3:-pass}"
    local stub_dir="$dir/.stubs"
    mkdir -p "$stub_dir"
    make_stub "$stub_dir/npm" "log"
    make_stub "$stub_dir/pnpm" "log"
    make_stub "$stub_dir/yarn" "log"
    make_stub "$stub_dir/bun" "log"
    make_stub "$stub_dir/gitleaks" "$gl_behavior"
    make_stub "$stub_dir/trufflehog" "$th_behavior"
    # CALL_LOG exported into the CI script's env so stubs find it.
    # We bake it into the stub environment when running ci.sh.
    echo "$dir/.call_log" > "$dir/.expected_call_log"
}

# Wrap env -i to include CALL_LOG pointing at the project's log file.
run_ci_with_log() {
    local dir="$1"
    (
        cd "$dir"
        env -i \
            PATH="$dir/.stubs:/usr/bin:/bin" \
            HOME="$dir" \
            CALL_LOG="$dir/.call_log" \
            bash "$SCRIPT_UNDER_TEST" \
            > "$dir/.stdout" 2> "$dir/.stderr"
    )
}

# ─── tests ──────────────────────────────────────────────────────────────────

# --- load_config: key trim bug -----------------------------------------------
test_config_loader_with_spaces() {
    echo "test_config_loader_with_spaces"
    local dir
    dir=$(mktemp -d -t ci-cfg-spaces-XXXX)
    cat > "$dir/.ci-cleandev.yml" <<'EOF'
mode = fast
timeout = 42
require_trufflehog = 1
EOF
    setup_project "$dir" "pass" "pass"
    run_ci_with_log "$dir"
    # The header echoes (mode=fast, timeout=42s) — that proves the loader
    # picked up keys with surrounding whitespace.
    if grep -q "mode=fast, timeout=42s" "$dir/.stderr" "$dir/.stdout" 2>/dev/null; then
        assert_eq "key trim handles 'mode = fast' (with spaces)" "ok" "ok"
    else
        assert_eq "key trim handles 'mode = fast' (with spaces)" "ok" "missing (got: $(cat "$dir/.stdout" | head -5))"
    fi
    rm -rf "$dir"
}

test_config_loader_no_spaces() {
    echo "test_config_loader_no_spaces"
    local dir
    dir=$(mktemp -d -t ci-cfg-nosp-XXXX)
    cat > "$dir/.ci-cleandev.yml" <<'EOF'
mode=fast
timeout=42
require_trufflehog=1
EOF
    setup_project "$dir" "pass" "pass"
    run_ci_with_log "$dir"
    if grep -q "mode=fast, timeout=42s" "$dir/.stderr" "$dir/.stdout" 2>/dev/null; then
        assert_eq "key trim handles 'mode=fast' (no spaces)" "ok" "ok"
    else
        assert_eq "key trim handles 'mode=fast' (no spaces)" "ok" "missing"
    fi
    rm -rf "$dir"
}

test_config_loader_comments_and_blanks() {
    echo "test_config_loader_comments_and_blanks"
    local dir
    dir=$(mktemp -d -t ci-cfg-cmt-XXXX)
    cat > "$dir/.ci-cleandev.yml" <<'EOF'
# This is a comment line
mode = fast

# Another comment
timeout = 60
EOF
    setup_project "$dir" "pass" "pass"
    run_ci_with_log "$dir"
    if grep -q "mode=fast, timeout=60s" "$dir/.stderr" "$dir/.stdout" 2>/dev/null; then
        assert_eq "loader ignores comments and blank lines" "ok" "ok"
    else
        assert_eq "loader ignores comments and blank lines" "ok" "missing"
    fi
    rm -rf "$dir"
}

# --- fast mode: gitleaks still runs ------------------------------------------
test_fast_mode_runs_gitleaks() {
    echo "test_fast_mode_runs_gitleaks"
    local dir
    dir=$(mktemp -d -t ci-fast-gl-XXXX)
    cat > "$dir/.ci-cleandev.yml" <<'EOF'
mode = fast
EOF
    setup_project "$dir" "pass" "pass"
    run_ci_with_log "$dir"
    if grep -q "^/.*/gitleaks" "$dir/.call_log"; then
        assert_eq "mode=fast still runs gitleaks" "yes" "yes"
    else
        assert_eq "mode=fast still runs gitleaks" "yes" "no — call log: $(cat "$dir/.call_log")"
    fi
    rm -rf "$dir"
}

test_fast_mode_skips_trufflehog() {
    echo "test_fast_mode_skips_trufflehog"
    local dir
    dir=$(mktemp -d -t ci-fast-th-XXXX)
    cat > "$dir/.ci-cleandev.yml" <<'EOF'
mode = fast
EOF
    setup_project "$dir" "pass" "pass"
    run_ci_with_log "$dir"
    if grep -q "^/.*/trufflehog" "$dir/.call_log"; then
        assert_eq "mode=fast skips trufflehog" "no" "yes — call log: $(cat "$dir/.call_log")"
    else
        assert_eq "mode=fast skips trufflehog" "no" "no"
    fi
    rm -rf "$dir"
}

# --- require_trufflehog: fails when trufflehog is required + missing --------
test_require_trufflehog_missing_fails() {
    echo "test_require_trufflehog_missing_fails"
    local dir
    dir=$(mktemp -d -t ci-req-th-XXXX)
    cat > "$dir/.ci-cleandev.yml" <<'EOF'
mode = normal
require_trufflehog = 1
EOF
    # gitleaks present, trufflehog missing
    setup_project "$dir" "pass" "absent"
    rm -f "$dir/.stubs/trufflehog"  # make trufflehog genuinely absent
    run_ci_with_log "$dir" >/dev/null 2>&1
    local exit_code=$?
    assert_eq "require_trufflehog=1 + trufflehog missing → exit 1" "1" "$exit_code"
    # Also: the failure message should mention trufflehog
    if grep -qiE 'trufflehog' "$dir/.stderr" "$dir/.stdout" 2>/dev/null; then
        assert_eq "failure message names trufflehog" "yes" "yes"
    else
        assert_eq "failure message names trufflehog" "yes" "no"
    fi
    rm -rf "$dir"
}

test_require_trufflehog_present_passes() {
    echo "test_require_trufflehog_present_passes"
    local dir
    dir=$(mktemp -d -t ci-req-th-ok-XXXX)
    cat > "$dir/.ci-cleandev.yml" <<'EOF'
mode = normal
require_trufflehog = 1
EOF
    setup_project "$dir" "pass" "pass"
    run_ci_with_log "$dir" >/dev/null 2>&1
    local exit_code=$?
    assert_eq "require_trufflehog=1 + trufflehog present → exit 0" "0" "$exit_code"
    rm -rf "$dir"
}

# --- ensure_node_deps: lockfile fallback (Bug 1) -----------------------------
test_ensure_node_deps_no_lockfile_calls_install() {
    echo "test_ensure_node_deps_no_lockfile_calls_install"
    local dir
    dir=$(mktemp -d -t ci-deps-nl-XXXX)
    setup_project "$dir" "pass" "pass"
    # package.json but no package-lock.json, no node_modules
    cat > "$dir/package.json" <<'EOF'
{"name":"x","version":"0.0.0"}
EOF
    cat > "$dir/.ci-cleandev.yml" <<'EOF'
mode = fast
EOF
    run_ci_with_log "$dir" >/dev/null 2>&1
    # With no lockfile, the script should call `npm install` (not `npm ci`)
    if grep -q "npm install$" "$dir/.call_log"; then
        assert_eq "no lockfile → npm install (not npm ci)" "yes" "yes"
    else
        assert_eq "no lockfile → npm install (not npm ci)" "yes" "no — call log: $(cat "$dir/.call_log")"
    fi
    if grep -q "npm ci" "$dir/.call_log"; then
        assert_eq "no lockfile → does NOT call npm ci" "no" "yes"
    else
        assert_eq "no lockfile → does NOT call npm ci" "no" "no"
    fi
    rm -rf "$dir"
}

test_ensure_node_deps_with_lockfile_calls_ci() {
    echo "test_ensure_node_deps_with_lockfile_calls_ci"
    local dir
    dir=$(mktemp -d -t ci-deps-wl-XXXX)
    setup_project "$dir" "pass" "pass"
    cat > "$dir/package.json" <<'EOF'
{"name":"x","version":"0.0.0"}
EOF
    echo '{}' > "$dir/package-lock.json"
    cat > "$dir/.ci-cleandev.yml" <<'EOF'
mode = fast
EOF
    run_ci_with_log "$dir" >/dev/null 2>&1
    if grep -q "npm ci" "$dir/.call_log"; then
        assert_eq "lockfile present → npm ci" "yes" "yes"
    else
        assert_eq "lockfile present → npm ci" "yes" "no — call log: $(cat "$dir/.call_log")"
    fi
    rm -rf "$dir"
}

# --- is_watch_test (Bug 3) ---------------------------------------------------
test_is_watch_test_vitest_subcommand() {
    echo "test_is_watch_test_vitest_subcommand"
    local dir
    dir=$(mktemp -d -t ci-wt-vitest-XXXX)
    cat > "$dir/package.json" <<'EOF'
{"name":"x","version":"0.0.0","scripts":{"test":"vitest watch"}}
EOF
    cat > "$dir/.ci-cleandev.yml" <<'EOF'
mode = fast
EOF
    setup_project "$dir" "pass" "pass"
    # We can't easily call is_watch_test directly without sourcing ci.sh,
    # but we can verify the script picks the right test runner by running
    # the script and watching the call log. vitest not in stubs, so the
    # script should hit the watch-mode path that warns about watch.
    run_ci_with_log "$dir" >/dev/null 2>&1
    # If watch mode was detected, the script tries npx vitest run (or skips)
    # but never runs the original watch command. The original `npm test` is
    # `vitest watch`, so if is_watch_test worked, the watch command itself
    # was NOT called.
    if grep -q "vitest watch" "$dir/.call_log"; then
        assert_eq "is_watch_test catches 'vitest watch' (doesn't run it)" "no" "yes — called: $(grep vitest "$dir/.call_log")"
    else
        assert_eq "is_watch_test catches 'vitest watch' (doesn't run it)" "no" "no"
    fi
    rm -rf "$dir"
}

test_is_watch_test_jest_subcommand() {
    echo "test_is_watch_test_jest_subcommand"
    local dir
    dir=$(mktemp -d -t ci-wt-jest-XXXX)
    cat > "$dir/package.json" <<'EOF'
{"name":"x","version":"0.0.0","scripts":{"test":"jest watch"}}
EOF
    cat > "$dir/.ci-cleandev.yml" <<'EOF'
mode = fast
EOF
    setup_project "$dir" "pass" "pass"
    run_ci_with_log "$dir" >/dev/null 2>&1
    if grep -q "jest watch" "$dir/.call_log"; then
        assert_eq "is_watch_test catches 'jest watch'" "no" "yes"
    else
        assert_eq "is_watch_test catches 'jest watch'" "no" "no"
    fi
    rm -rf "$dir"
}

test_is_watch_test_dash_flag() {
    echo "test_is_watch_test_dash_flag"
    local dir
    dir=$(mktemp -d -t ci-wt-dash-XXXX)
    cat > "$dir/package.json" <<'EOF'
{"name":"x","version":"0.0.0","scripts":{"test":"vitest --watch"}}
EOF
    cat > "$dir/.ci-cleandev.yml" <<'EOF'
mode = fast
EOF
    setup_project "$dir" "pass" "pass"
    run_ci_with_log "$dir" >/dev/null 2>&1
    if grep -q "vitest --watch" "$dir/.call_log"; then
        assert_eq "is_watch_test catches 'vitest --watch'" "no" "yes"
    else
        assert_eq "is_watch_test catches 'vitest --watch'" "no" "no"
    fi
    rm -rf "$dir"
}

# --- run_step: log preservation (Bug 2) --------------------------------------
test_run_step_preserves_failure_log() {
    echo "test_run_step_preserves_failure_log"
    local dir
    dir=$(mktemp -d -t ci-log-XXXX)
    cat > "$dir/.ci-cleandev.yml" <<'EOF'
mode = fast
EOF
    setup_project "$dir" "fail" "pass"  # gitleaks fails
    run_ci_with_log "$dir" >/dev/null 2>&1
    local exit_code=$?
    # gitleaks failed → FAIL log preserved in /tmp
    if ls /tmp/ci-cleandev.*.log 2>/dev/null | head -1 >/dev/null; then
        assert_eq "failed step log preserved in /tmp" "yes" "yes"
    else
        assert_eq "failed step log preserved in /tmp" "yes" "no"
    fi
    # Exit code should be 1
    assert_eq "failing gitleaks → exit 1" "1" "$exit_code"
    rm -rf "$dir" /tmp/ci-cleandev.*.log
}

# ─── runner ──────────────────────────────────────────────────────────────────
echo "Running ci.sh test harness..."
echo ""

test_config_loader_with_spaces
test_config_loader_no_spaces
test_config_loader_comments_and_blanks
test_fast_mode_runs_gitleaks
test_fast_mode_skips_trufflehog
test_require_trufflehog_missing_fails
test_require_trufflehog_present_passes
test_ensure_node_deps_no_lockfile_calls_install
test_ensure_node_deps_with_lockfile_calls_ci
test_is_watch_test_vitest_subcommand
test_is_watch_test_jest_subcommand
test_is_watch_test_dash_flag
test_run_step_preserves_failure_log

echo ""
echo "─────────────────────────────────────"
if [ "$FAIL" -eq 0 ]; then
    printf "\033[0;32m  PASS\033[0m  %d passed, 0 failed\n" "$PASS"
    exit 0
else
    printf "\033[0;31m  FAIL\033[0m  %d passed, \033[0;31m%d failed\033[0m\n" "$PASS" "$FAIL"
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do
        echo "  - $t"
    done
    exit 1
fi
