#!/usr/bin/env bash
# ci-cleandev — universal pre-push CI runner
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0

run_step() {
    local label="$1"
    shift
    printf "  %-40s " "$label"
    if "$@" > /tmp/ci-step.log 2>&1; then
        echo -e "${GREEN}PASS${NC}"
        ((PASS++))
    else
        echo -e "${RED}FAIL${NC}"
        cat /tmp/ci-step.log
        ((FAIL++))
    fi
}

echo ""
echo -e "${YELLOW}=== CI: $(basename "$(pwd)") ===${NC}"

# ---- Build ----
if [ -f package.json ]; then
    if grep -q '"build"' package.json 2>/dev/null; then
        run_step "build" npm run build
    elif grep -q '"compile"' package.json 2>/dev/null; then
        run_step "build" npm run compile
    fi
fi

# ---- Lint ----
if grep -q '"lint"' package.json 2>/dev/null; then
    run_step "lint" npm run lint
fi

# ---- Test ----
if grep -q '"test"' package.json 2>/dev/null; then
    run_step "test" npm test
fi

# ---- Secret sweep (trufflehog) ----
if command -v trufflehog &>/dev/null; then
    run_step "secrets" trufflehog filesystem --no-update --directory=. --json
else
    echo -e "  ${YELLOW}secrets${NC}               SKIP (trufflehog not installed)"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo -e "${RED}CI FAILED — $FAIL step(s) failed, $PASS passed${NC}"
    exit 1
else
    echo -e "${GREEN}CI PASSED — $PASS step(s) ok${NC}"
    exit 0
fi
