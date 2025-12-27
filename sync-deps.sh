#!/usr/bin/env bash
#
# Sync dependencies across all livetemplate repos via PRs
#
# This script detects which repos need dependency updates and creates
# PRs to update them to the latest published versions.
#
# Usage:
#   ./sync-deps.sh           # Analyze and create PRs
#   ./sync-deps.sh --dry-run # Show plan without making changes
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Functions
log_info() { echo -e "${GREEN}✓${NC} $1"; }
log_warn() { echo -e "${YELLOW}⚠${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1"; }
log_step() { echo -e "${BLUE}▸${NC} $1"; }

# Script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Dependency graph: downstream repos
DOWNSTREAM_REPOS="components lvt tinkerdown examples"

# Get upstream dependencies for a repo
get_deps() {
    local repo=$1
    case "$repo" in
        components) echo "livetemplate" ;;
        lvt) echo "livetemplate" ;;
        tinkerdown) echo "livetemplate components" ;;
        examples) echo "livetemplate components lvt" ;;
        *) echo "" ;;
    esac
}

# GitHub org
GITHUB_ORG="livetemplate"

# Global variable to store updates (one per line: repo|dep|current|latest)
UPDATES_FILE=""

# Parse flags
DRY_RUN=false
while [ $# -gt 0 ]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--dry-run]"
            echo ""
            echo "Sync dependencies across all livetemplate repos via PRs."
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
    local missing=""

    command -v gh >/dev/null 2>&1 || missing="$missing gh"
    command -v go >/dev/null 2>&1 || missing="$missing go"
    command -v jq >/dev/null 2>&1 || missing="$missing jq"

    if [ -n "$missing" ]; then
        log_error "Missing required tools:$missing"
        echo ""
        echo "Install with:"
        echo "  macOS:   brew install gh jq"
        exit 1
    fi

    # Check GitHub CLI auth
    if ! gh auth status >/dev/null 2>&1; then
        log_error "GitHub CLI not authenticated. Run 'gh auth login' first"
        exit 1
    fi
}

# Get latest release tag for a repo
get_latest_release() {
    local repo=$1
    local tag

    tag=$(gh release list --repo "${GITHUB_ORG}/${repo}" --limit 1 --json tagName -q '.[0].tagName' 2>/dev/null || echo "")

    if [ -z "$tag" ]; then
        echo ""
        return
    fi

    echo "$tag"
}

# Get current version of a dependency in a repo's go.mod
get_current_version() {
    local repo=$1
    local dep=$2
    local repo_path="${SCRIPT_DIR}/${repo}"

    if [ ! -d "$repo_path" ]; then
        echo ""
        return
    fi

    if [ ! -f "$repo_path/go.mod" ]; then
        echo ""
        return
    fi

    # Extract version from go.mod
    local version
    version=$(grep "github.com/${GITHUB_ORG}/${dep} " "$repo_path/go.mod" 2>/dev/null | awk '{print $2}' | head -1)

    echo "$version"
}

# Analyze all repos for updates and write to temp file
analyze_updates() {
    local update_count=0

    # Create temp file for updates
    UPDATES_FILE=$(mktemp)

    for repo in $DOWNSTREAM_REPOS; do
        local deps
        deps=$(get_deps "$repo")

        for dep in $deps; do
            local current_version
            local latest_version

            current_version=$(get_current_version "$repo" "$dep")
            latest_version=$(get_latest_release "$dep")

            if [ -z "$current_version" ]; then
                continue
            fi

            if [ -z "$latest_version" ]; then
                continue
            fi

            # Compare versions (strip 'v' prefix for comparison)
            local current_clean="${current_version#v}"
            local latest_clean="${latest_version#v}"

            local needs_update=false

            # Handle pseudo-versions (e.g., v0.0.0-20251224004709-1f8c1de230b4)
            case "$current_version" in
                *-*)
                    case "$latest_version" in
                        *-*) ;;
                        *) needs_update=true ;;
                    esac
                    ;;
                *)
                    if [ "$current_clean" != "$latest_clean" ]; then
                        needs_update=true
                    fi
                    ;;
            esac

            if [ "$needs_update" = true ]; then
                echo "${repo}|${dep}|${current_version}|${latest_version}" >> "$UPDATES_FILE"
                update_count=$((update_count + 1))
            fi
        done
    done

    echo "$update_count"
}

# Display update plan
show_plan() {
    local dry_run_label=""

    if [ "$DRY_RUN" = true ]; then
        dry_run_label=" (DRY RUN)"
    fi

    echo ""
    echo -e "${CYAN}Dependency Update Plan${dry_run_label}:${NC}"
    echo ""

    if [ ! -s "$UPDATES_FILE" ]; then
        log_info "All dependencies are up to date!"
        return 0
    fi

    # Print table header
    printf "%-12s %-20s %-20s %-12s\n" "Repo" "Dependency" "Current" "Latest"
    printf "%-12s %-20s %-20s %-12s\n" "----" "----------" "-------" "------"

    # Track unique repos
    local repos_needing_update=""

    while IFS='|' read -r repo dep current latest; do
        # Truncate long versions for display
        local current_display
        local latest_display
        current_display=$(echo "$current" | cut -c1-18)
        latest_display=$(echo "$latest" | cut -c1-10)

        printf "%-12s %-20s %-20s %-12s\n" "$repo" "$dep" "$current_display" "$latest_display"

        # Add repo to list if not already there
        case " $repos_needing_update " in
            *" $repo "*) ;;
            *) repos_needing_update="$repos_needing_update $repo" ;;
        esac
    done < "$UPDATES_FILE"

    echo ""
    echo -e "Repos needing PRs:${GREEN}${repos_needing_update}${NC}"

    return 0
}

# Create branch, update go.mod, and create PR
create_pr_for_repo() {
    local repo=$1
    local repo_path="${SCRIPT_DIR}/${repo}"
    local branch_name="deps/update-$(date +%Y-%m-%d)"
    local pr_title="chore(deps): update livetemplate dependencies"

    log_step "Updating $repo..."

    cd "$repo_path"

    # Check if repo is clean
    if [ -n "$(git status --porcelain)" ]; then
        log_warn "$repo has uncommitted changes, skipping"
        return 1
    fi

    # Fetch latest
    git fetch origin

    # Get default branch
    local default_branch
    default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")

    # Checkout default branch and create feature branch
    git checkout "$default_branch"
    git pull origin "$default_branch"

    # Delete branch if it exists
    git branch -D "$branch_name" 2>/dev/null || true
    git checkout -b "$branch_name"

    # Collect updates for this repo
    local pr_body="## Dependency Updates\n\n"
    local has_changes=false

    while IFS='|' read -r update_repo dep current latest; do
        if [ "$update_repo" = "$repo" ]; then
            log_step "  Updating $dep: $current -> $latest"

            if go get "github.com/${GITHUB_ORG}/${dep}@${latest}" 2>/dev/null; then
                pr_body="${pr_body}- **$dep**: \`$current\` -> \`$latest\`\n"
                has_changes=true
            else
                log_error "Failed to update $dep in $repo"
            fi
        fi
    done < "$UPDATES_FILE"

    if [ "$has_changes" = false ]; then
        log_warn "$repo: No updates applied"
        git checkout "$default_branch"
        git branch -D "$branch_name" 2>/dev/null || true
        return 0
    fi

    # Run go mod tidy
    log_step "  Running go mod tidy"
    go mod tidy

    # Check if there are changes
    if [ -z "$(git status --porcelain)" ]; then
        log_warn "$repo: No changes after update (already up to date?)"
        git checkout "$default_branch"
        git branch -D "$branch_name" 2>/dev/null || true
        return 0
    fi

    # Commit changes
    git add go.mod go.sum
    git commit -m "$pr_title

$(echo -e "$pr_body")

Generated by sync-deps.sh"

    # Push branch
    git push -u origin "$branch_name" --force

    # Create PR
    pr_body="${pr_body}\n---\n\nGenerated by \`sync-deps.sh\`"

    if gh pr create \
        --title "$pr_title" \
        --body "$(echo -e "$pr_body")" \
        --head "$branch_name" \
        --base "$default_branch" 2>/dev/null; then
        log_info "Created PR for $repo"
    else
        # PR might already exist
        log_warn "PR may already exist for $repo, updating..."
    fi

    # Switch back to default branch
    git checkout "$default_branch"
}

# Cleanup temp file
cleanup() {
    if [ -n "$UPDATES_FILE" ] && [ -f "$UPDATES_FILE" ]; then
        rm -f "$UPDATES_FILE"
    fi
}
trap cleanup EXIT

# Main function
main() {
    echo ""
    if [ "$DRY_RUN" = true ]; then
        echo -e "${CYAN}Sync Dependencies (DRY RUN)${NC}"
    else
        echo -e "${CYAN}Sync Dependencies${NC}"
    fi
    echo "=============================="
    echo ""

    check_prerequisites

    log_step "Analyzing dependencies..."

    local update_count
    update_count=$(analyze_updates)

    show_plan

    if [ ! -s "$UPDATES_FILE" ]; then
        exit 0
    fi

    if [ "$DRY_RUN" = true ]; then
        echo ""
        echo -e "${YELLOW}(dry-run: no changes made)${NC}"
        exit 0
    fi

    echo ""
    read -rp "Create PRs for updates? [y/N]: " confirm

    case "$confirm" in
        [Yy]*) ;;
        *)
            log_warn "Cancelled"
            exit 0
            ;;
    esac

    echo ""

    # Get unique repos that need updates
    local repos_to_update=""
    while IFS='|' read -r repo _ _ _; do
        case " $repos_to_update " in
            *" $repo "*) ;;
            *) repos_to_update="$repos_to_update $repo" ;;
        esac
    done < "$UPDATES_FILE"

    # Create PRs for each repo
    for repo in $repos_to_update; do
        create_pr_for_repo "$repo" || {
            log_error "Failed to create PR for $repo"
            continue
        }
    done

    echo ""
    echo "=============================="
    log_info "Sync complete!"
}

main "$@"
