#!/usr/bin/env bash
#
# Release all livetemplate repos in dependency order
#
# This script orchestrates the release of all repos, ensuring dependencies
# are updated before each tier is released.
#
# Usage:
#   ./release-all.sh           # Interactive release workflow
#   ./release-all.sh --dry-run # Show plan without making changes
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Functions
log_info() { echo -e "${GREEN}✓${NC} $1"; }
log_warn() { echo -e "${YELLOW}⚠${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1"; }
log_step() { echo -e "${BLUE}▸${NC} $1"; }
log_header() { echo -e "\n${BOLD}${CYAN}[$1]${NC}\n"; }

# Script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Release order (tiers)
# Tier 1: Core library (no dependencies)
# Tier 2: Components (depends on core)
# Tier 3: lvt, tinkerdown (depend on core, components)
# Tier 4: Examples (depends on all)
declare -a TIER_1=("livetemplate")
declare -a TIER_2=("components")
declare -a TIER_3=("lvt" "tinkerdown")
declare -a TIER_4=("examples")

# Repos that have releases (not just dependency updates)
declare -a RELEASABLE_REPOS=("livetemplate" "components" "lvt" "tinkerdown")

# GitHub org
GITHUB_ORG="livetemplate"

# Parse flags
DRY_RUN=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--dry-run]"
            echo ""
            echo "Release all livetemplate repos in dependency order."
            echo ""
            echo "Options:"
            echo "  --dry-run    Show what would be done without making changes"
            echo "  -h, --help   Show this help message"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check prerequisites
check_prerequisites() {
    local missing=()

    command -v gh >/dev/null 2>&1 || missing+=("gh (GitHub CLI)")
    command -v go >/dev/null 2>&1 || missing+=("go")

    if [ ${#missing[@]} -ne 0 ]; then
        log_error "Missing required tools: ${missing[*]}"
        exit 1
    fi

    # Check GitHub CLI auth
    if ! gh auth status >/dev/null 2>&1; then
        log_error "GitHub CLI not authenticated. Run 'gh auth login' first"
        exit 1
    fi
}

# Check if repo exists locally
check_repo_exists() {
    local repo=$1
    local repo_path="${SCRIPT_DIR}/${repo}"

    if [ ! -d "$repo_path" ]; then
        return 1
    fi

    if [ ! -f "$repo_path/go.mod" ]; then
        return 1
    fi

    return 0
}

# Check if repo has uncommitted changes
check_repo_clean() {
    local repo=$1
    local repo_path="${SCRIPT_DIR}/${repo}"

    cd "$repo_path"

    if [ -n "$(git status --porcelain)" ]; then
        return 1
    fi

    return 0
}

# Get current version from VERSION file
get_current_version() {
    local repo=$1
    local repo_path="${SCRIPT_DIR}/${repo}"

    if [ -f "$repo_path/VERSION" ]; then
        cat "$repo_path/VERSION" | tr -d '\n'
    else
        echo "unknown"
    fi
}

# Get latest release tag from GitHub
get_latest_release() {
    local repo=$1

    gh release list --repo "${GITHUB_ORG}/${repo}" --limit 1 --json tagName -q '.[0].tagName' 2>/dev/null || echo ""
}

# Run tests for a repo
run_tests() {
    local repo=$1
    local repo_path="${SCRIPT_DIR}/${repo}"

    cd "$repo_path"

    # Check for go.mod
    if [ ! -f "go.mod" ]; then
        log_warn "$repo: no go.mod found, skipping tests"
        return 0
    fi

    log_step "Testing $repo..."

    if ! go test ./... -timeout=120s 2>&1; then
        return 1
    fi

    return 0
}

# Pre-flight checks
preflight_checks() {
    log_header "Pre-flight Checks"

    local all_repos=("${TIER_1[@]}" "${TIER_2[@]}" "${TIER_3[@]}" "${TIER_4[@]}")
    local failed=false

    # Check all repos exist
    log_step "Checking repos exist..."
    for repo in "${all_repos[@]}"; do
        if ! check_repo_exists "$repo"; then
            log_error "$repo: not found at ${SCRIPT_DIR}/${repo}"
            failed=true
        else
            log_info "$repo: found"
        fi
    done

    if [ "$failed" = true ]; then
        log_error "Some repos are missing. Clone them first."
        exit 1
    fi

    # Check all repos are clean
    log_step "Checking repos are clean..."
    for repo in "${all_repos[@]}"; do
        if ! check_repo_clean "$repo"; then
            log_error "$repo: has uncommitted changes"
            failed=true
        else
            log_info "$repo: clean"
        fi
    done

    if [ "$failed" = true ]; then
        log_error "Some repos have uncommitted changes. Commit or stash them first."
        exit 1
    fi

    # Run tests for all repos
    log_step "Running tests across all repos..."
    for repo in "${all_repos[@]}"; do
        if ! run_tests "$repo"; then
            log_error "$repo: tests failed"
            failed=true
        else
            log_info "$repo: tests passed"
        fi
    done

    if [ "$failed" = true ]; then
        log_error "Some tests failed. Fix them before releasing."
        exit 1
    fi

    log_info "All pre-flight checks passed"
}

# Show release plan
show_release_plan() {
    log_header "Release Plan"

    local step=1

    echo "The following repos will be released in order:"
    echo ""

    for tier_name in "TIER_1" "TIER_2" "TIER_3" "TIER_4"; do
        local -n tier="$tier_name"

        for repo in "${tier[@]}"; do
            local current_version
            local is_releasable=false

            current_version=$(get_current_version "$repo")

            # Check if repo is releasable
            for r in "${RELEASABLE_REPOS[@]}"; do
                if [ "$r" = "$repo" ]; then
                    is_releasable=true
                    break
                fi
            done

            if [ "$is_releasable" = true ]; then
                printf "  %d. %-15s v%-10s -> (new version)\n" "$step" "$repo" "$current_version"
            else
                printf "  %d. %-15s (dependency update only)\n" "$step" "$repo"
            fi
            ((step++))
        done
    done

    echo ""
    echo "Between each tier, dependency update PRs will be created."
}

# Release a single repo using its release.sh
release_repo() {
    local repo=$1
    local repo_path="${SCRIPT_DIR}/${repo}"

    if [ ! -f "$repo_path/scripts/release.sh" ]; then
        log_warn "$repo: no release.sh found, skipping"
        return 0
    fi

    cd "$repo_path"

    if [ "$DRY_RUN" = true ]; then
        log_step "$repo: Would run ./scripts/release.sh --dry-run"
        ./scripts/release.sh --dry-run 2>&1 || true
    else
        log_step "$repo: Running release..."
        ./scripts/release.sh
    fi
}

# Create dependency PRs using sync-deps.sh
create_dependency_prs() {
    local sync_script="${SCRIPT_DIR}/sync-deps.sh"

    if [ ! -f "$sync_script" ]; then
        log_error "sync-deps.sh not found"
        return 1
    fi

    if [ "$DRY_RUN" = true ]; then
        "$sync_script" --dry-run
    else
        "$sync_script"
    fi
}

# Wait for user to merge PRs
wait_for_pr_merge() {
    if [ "$DRY_RUN" = true ]; then
        log_step "(dry-run: would wait for PR merge)"
        return 0
    fi

    echo ""
    echo -e "${YELLOW}Please review and merge the dependency update PRs before continuing.${NC}"
    echo ""
    read -rp "Press Enter when PRs are merged (or Ctrl+C to abort)..."
    echo ""
}

# Main function
main() {
    echo ""
    if [ "$DRY_RUN" = true ]; then
        echo -e "${BOLD}${CYAN}LiveTemplate Full Release (DRY RUN)${NC}"
    else
        echo -e "${BOLD}${CYAN}LiveTemplate Full Release${NC}"
    fi
    echo "========================================"
    echo ""

    check_prerequisites

    # Pre-flight checks
    preflight_checks

    # Show release plan
    show_release_plan

    if [ "$DRY_RUN" = true ]; then
        echo ""
        echo -e "${YELLOW}(dry-run: no changes will be made)${NC}"
        echo ""

        # Show what would happen for each tier
        log_header "Dry Run: Tier 1 (Core)"
        for repo in "${TIER_1[@]}"; do
            release_repo "$repo"
        done

        log_header "Dry Run: Dependency Updates"
        create_dependency_prs

        log_header "Dry Run: Tier 2"
        for repo in "${TIER_2[@]}"; do
            release_repo "$repo"
        done

        log_header "Dry Run: Tier 3"
        for repo in "${TIER_3[@]}"; do
            release_repo "$repo"
        done

        echo ""
        echo "========================================"
        log_info "Dry run complete - no changes made"
        exit 0
    fi

    # Confirm before proceeding
    echo ""
    read -rp "Proceed with release? [y/N]: " confirm

    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        log_warn "Release cancelled"
        exit 0
    fi

    # Tier 1: Release core library
    log_header "Step 1: Release Core Library"
    for repo in "${TIER_1[@]}"; do
        release_repo "$repo"
    done

    # Create dependency PRs for tier 2
    log_header "Step 2: Create Dependency PRs for Tier 2"
    create_dependency_prs

    wait_for_pr_merge

    # Tier 2: Release components
    log_header "Step 3: Release Components"
    for repo in "${TIER_2[@]}"; do
        release_repo "$repo"
    done

    # Create dependency PRs for tier 3
    log_header "Step 4: Create Dependency PRs for Tier 3"
    create_dependency_prs

    wait_for_pr_merge

    # Tier 3: Release lvt and tinkerdown
    log_header "Step 5: Release CLI and Tinkerdown"
    for repo in "${TIER_3[@]}"; do
        release_repo "$repo"
    done

    # Create dependency PRs for tier 4 (examples)
    log_header "Step 6: Update Examples"
    create_dependency_prs

    # Summary
    echo ""
    echo "========================================"
    log_info "All releases complete!"
    echo ""
    echo "Released repos:"
    for repo in "${RELEASABLE_REPOS[@]}"; do
        local version
        version=$(get_latest_release "$repo")
        echo "  - ${GITHUB_ORG}/${repo}@${version:-'(check GitHub)'}"
    done
    echo ""
    echo "Next steps:"
    echo "  - Verify releases on GitHub"
    echo "  - Merge any remaining dependency update PRs"
    echo "  - Update documentation if needed"
}

main "$@"
