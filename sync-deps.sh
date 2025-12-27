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

# Dependency graph: downstream repo -> space-separated upstream repos
declare -A DEPS=(
    ["components"]="livetemplate"
    ["lvt"]="livetemplate"
    ["tinkerdown"]="livetemplate components"
    ["examples"]="livetemplate components lvt"
)

# All repos in the ecosystem
ALL_REPOS=("livetemplate" "components" "lvt" "tinkerdown" "examples")

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
    local missing=()

    command -v gh >/dev/null 2>&1 || missing+=("gh (GitHub CLI)")
    command -v go >/dev/null 2>&1 || missing+=("go")
    command -v jq >/dev/null 2>&1 || missing+=("jq")

    if [ ${#missing[@]} -ne 0 ]; then
        log_error "Missing required tools: ${missing[*]}"
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
        log_warn "Repo not found locally: $repo_path"
        echo ""
        return
    fi

    if [ ! -f "$repo_path/go.mod" ]; then
        log_warn "go.mod not found in $repo"
        echo ""
        return
    fi

    # Extract version from go.mod
    local version
    version=$(grep "github.com/${GITHUB_ORG}/${dep} " "$repo_path/go.mod" 2>/dev/null | awk '{print $2}' | head -1)

    echo "$version"
}

# Analyze all repos for updates
analyze_updates() {
    local -n updates_ref=$1
    local update_count=0

    for repo in "${!DEPS[@]}"; do
        local deps="${DEPS[$repo]}"

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

            # Handle pseudo-versions (e.g., v0.0.0-20251224004709-1f8c1de230b4)
            if [[ "$current_version" == *"-"* ]] && [[ ! "$latest_version" == *"-"* ]]; then
                # Current is pseudo-version, latest is release - needs update
                updates_ref+=("${repo}|${dep}|${current_version}|${latest_version}")
                ((update_count++))
            elif [ "$current_clean" != "$latest_clean" ]; then
                updates_ref+=("${repo}|${dep}|${current_version}|${latest_version}")
                ((update_count++))
            fi
        done
    done

    echo "$update_count"
}

# Display update plan
show_plan() {
    local -n updates_ref=$1
    local dry_run_label=""

    if [ "$DRY_RUN" = true ]; then
        dry_run_label=" (DRY RUN)"
    fi

    echo ""
    echo -e "${CYAN}Dependency Update Plan${dry_run_label}:${NC}"
    echo ""

    if [ ${#updates_ref[@]} -eq 0 ]; then
        log_info "All dependencies are up to date!"
        return 0
    fi

    # Print table header
    printf "%-12s %-20s %-20s %-12s\n" "Repo" "Dependency" "Current" "Latest"
    printf "%-12s %-20s %-20s %-12s\n" "----" "----------" "-------" "------"

    # Collect unique repos that need updates
    declare -A repos_to_update

    for update in "${updates_ref[@]}"; do
        IFS='|' read -r repo dep current latest <<< "$update"

        # Truncate long versions for display
        local current_display="${current:0:18}"
        local latest_display="${latest:0:10}"

        printf "%-12s %-20s %-20s %-12s\n" "$repo" "$dep" "$current_display" "$latest_display"
        repos_to_update["$repo"]=1
    done

    echo ""
    echo -e "Repos needing PRs: ${GREEN}${!repos_to_update[*]}${NC}"

    return ${#updates_ref[@]}
}

# Create branch, update go.mod, and create PR
create_pr_for_repo() {
    local repo=$1
    shift
    local updates=("$@")

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

    # Create branch
    git checkout -b "$branch_name" 2>/dev/null || {
        # Branch might already exist, try to check it out
        git checkout "$branch_name" 2>/dev/null || {
            log_error "Failed to create/checkout branch $branch_name in $repo"
            return 1
        }
    }

    # Update each dependency
    local pr_body="## Dependency Updates\n\n"

    for update in "${updates[@]}"; do
        IFS='|' read -r _ dep current latest <<< "$update"

        log_step "  Updating $dep: $current -> $latest"

        go get "github.com/${GITHUB_ORG}/${dep}@${latest}" 2>/dev/null || {
            log_error "Failed to update $dep in $repo"
            git checkout main 2>/dev/null || git checkout master 2>/dev/null
            git branch -D "$branch_name" 2>/dev/null || true
            return 1
        }

        pr_body+="- **$dep**: \`$current\` -> \`$latest\`\n"
    done

    # Run go mod tidy
    log_step "  Running go mod tidy"
    go mod tidy

    # Check if there are changes
    if [ -z "$(git status --porcelain)" ]; then
        log_warn "$repo: No changes after update (already up to date?)"
        git checkout main 2>/dev/null || git checkout master 2>/dev/null
        git branch -D "$branch_name" 2>/dev/null || true
        return 0
    fi

    # Commit changes
    git add go.mod go.sum
    git commit -m "$pr_title

$(echo -e "$pr_body")

Generated by sync-deps.sh"

    # Push branch
    git push -u origin "$branch_name"

    # Create PR
    pr_body+="\n---\n\nGenerated by \`sync-deps.sh\`"

    gh pr create \
        --title "$pr_title" \
        --body "$(echo -e "$pr_body")" \
        --head "$branch_name" \
        --base main || gh pr create \
            --title "$pr_title" \
            --body "$(echo -e "$pr_body")" \
            --head "$branch_name" \
            --base master

    # Switch back to main/master
    git checkout main 2>/dev/null || git checkout master 2>/dev/null

    log_info "Created PR for $repo"
}

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

    declare -a updates=()
    local update_count
    update_count=$(analyze_updates updates)

    show_plan updates

    if [ ${#updates[@]} -eq 0 ]; then
        exit 0
    fi

    if [ "$DRY_RUN" = true ]; then
        echo ""
        echo -e "${YELLOW}(dry-run: no changes made)${NC}"
        exit 0
    fi

    echo ""
    read -rp "Create PRs for updates? [y/N]: " confirm

    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        log_warn "Cancelled"
        exit 0
    fi

    echo ""

    # Group updates by repo
    declare -A repo_updates
    for update in "${updates[@]}"; do
        IFS='|' read -r repo _ _ _ <<< "$update"
        if [ -z "${repo_updates[$repo]:-}" ]; then
            repo_updates["$repo"]="$update"
        else
            repo_updates["$repo"]="${repo_updates[$repo]}|SEP|$update"
        fi
    done

    # Create PRs for each repo
    for repo in "${!repo_updates[@]}"; do
        # Split updates back into array
        IFS='|SEP|' read -ra repo_update_list <<< "${repo_updates[$repo]}"

        create_pr_for_repo "$repo" "${repo_update_list[@]}" || {
            log_error "Failed to create PR for $repo"
            continue
        }
    done

    echo ""
    echo "=============================="
    log_info "Sync complete!"
}

main "$@"
