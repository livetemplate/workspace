#!/bin/bash
#
# Setup Go workspace for LiveTemplate local development
#
# This creates a go.work file that automatically uses local versions
# of all LiveTemplate repositories without modifying go.mod files.
#
# Usage:
#   ./setup-workspace.sh          # Create workspace
#   ./setup-workspace.sh --clean  # Remove workspace
#
# Requirements:
#   - Go 1.18+ (for workspace support)
#   - All repos cloned as siblings in this directory

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

WORKSPACE_FILE="go.work"

# Check Go version
GO_VERSION=$(go version | awk '{print $3}' | sed 's/go//')
GO_MAJOR=$(echo $GO_VERSION | cut -d. -f1)
GO_MINOR=$(echo $GO_VERSION | cut -d. -f2)

if [ "$GO_MAJOR" -lt 1 ] || ([ "$GO_MAJOR" -eq 1 ] && [ "$GO_MINOR" -lt 18 ]); then
    echo -e "${RED}✗ Go 1.18+ required for workspace support${NC}"
    echo "  Current version: $GO_VERSION"
    exit 1
fi

# Check if cleaning
if [[ "$1" == "--clean" || "$1" == "clean" ]]; then
    if [ -f "$WORKSPACE_FILE" ]; then
        rm "$WORKSPACE_FILE"
        echo -e "${GREEN}✓ Workspace removed${NC}"
        echo ""
        echo "All repositories now use published versions."
    else
        echo "No workspace file found."
    fi
    exit 0
fi

# Repositories to include
REPOS=(
    "livetemplate"
    "lvt"
    "client"
)

# Examples to include (only working ones)
EXAMPLES=(
    "examples/counter"
    "examples/chat"
    "examples/todos"
    "examples/graceful-shutdown"
    "examples/testing/01_basic"
)

echo "Setting up Go workspace for LiveTemplate..."
echo ""

# Check which repos exist
FOUND_REPOS=()
MISSING_REPOS=()

for repo in "${REPOS[@]}"; do
    if [ -d "$repo" ] && [ -f "$repo/go.mod" ]; then
        FOUND_REPOS+=("$repo")
    else
        MISSING_REPOS+=("$repo")
    fi
done

# Check which examples exist
FOUND_EXAMPLES=()
for example in "${EXAMPLES[@]}"; do
    if [ -d "$example" ] && [ -f "$example/go.mod" ]; then
        FOUND_EXAMPLES+=("$example")
    fi
done

# Report what we found
if [ ${#FOUND_REPOS[@]} -eq 0 ]; then
    echo -e "${RED}✗ No repositories found${NC}"
    echo ""
    echo "Expected directory structure:"
    echo "  $(pwd)/"
    echo "  ├── livetemplate/  (core library)"
    echo "  ├── lvt/           (CLI tool)"
    echo "  ├── client/        (TypeScript client - optional)"
    echo "  └── examples/      (examples)"
    echo ""
    echo "Please clone the repositories:"
    echo "  git clone git@github.com:livetemplate/livetemplate.git"
    echo "  git clone git@github.com:livetemplate/lvt.git"
    echo "  git clone git@github.com:livetemplate/examples.git"
    exit 1
fi

echo -e "${GREEN}Found repositories:${NC}"
for repo in "${FOUND_REPOS[@]}"; do
    echo "  ✓ $repo"
done

if [ ${#FOUND_EXAMPLES[@]} -gt 0 ]; then
    echo ""
    echo -e "${GREEN}Found examples:${NC}"
    for example in "${FOUND_EXAMPLES[@]}"; do
        echo "  ✓ $example"
    done
fi

if [ ${#MISSING_REPOS[@]} -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}Missing (optional):${NC}"
    for repo in "${MISSING_REPOS[@]}"; do
        echo "  ⊘ $repo"
    done
fi

echo ""
echo "Creating $WORKSPACE_FILE..."

# Initialize workspace
go work init

# Add found repositories
for repo in "${FOUND_REPOS[@]}"; do
    go work use "./$repo"
done

# Add found examples
for example in "${FOUND_EXAMPLES[@]}"; do
    go work use "./$example"
done

echo ""
echo -e "${GREEN}✓ Go workspace created successfully!${NC}"
echo ""
echo "What this means:"
echo "  • All Go commands now use your local checkouts automatically"
echo "  • No go.mod changes needed"
echo "  • Changes in livetemplate immediately reflected in lvt/examples"
echo ""
echo "Usage:"
echo "  cd lvt && go test ./...           # Uses local livetemplate"
echo "  cd examples/counter && go build   # Uses local livetemplate + lvt"
echo ""
echo "To remove workspace and use published versions:"
echo "  ./setup-workspace.sh --clean"
echo ""
echo "Note: $WORKSPACE_FILE is gitignored and only affects your local environment."
