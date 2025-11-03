# LiveTemplate Development Workspace

This directory contains all LiveTemplate repositories for local development.

## Quick Start

```bash
# Setup workspace (one-time)
./setup-workspace.sh

# Now all repositories use local versions automatically
cd lvt && go test ./...
cd ../examples && ./test-all.sh
```

## Repository Structure

```
livetemplate/
├── livetemplate/          # Core Go library
├── lvt/                   # CLI tool
├── examples/              # Example applications
├── client/                # TypeScript client (optional)
├── setup-workspace.sh     # Workspace setup script
└── go.work                # Created by setup script (gitignored)
```

## What is a Go Workspace?

A Go workspace (introduced in Go 1.18) allows multiple modules to work together without modifying `go.mod` files. When you run `./setup-workspace.sh`, it creates a `go.work` file that tells Go to use your local checkouts instead of published versions.

**Benefits:**
- ✅ No `go.mod` changes needed
- ✅ Automatic local module resolution
- ✅ One-time setup affects all repositories
- ✅ Easy to enable/disable
- ✅ Never committed to git

## Usage

### Initial Setup

```bash
# Clone all repositories as siblings
git clone https://github.com/livetemplate/livetemplate.git
git clone https://github.com/livetemplate/lvt.git
git clone https://github.com/livetemplate/examples.git

# Optional: Clone client library
git clone https://github.com/livetemplate/client.git

# Create workspace
./setup-workspace.sh
```

### Daily Development

Once the workspace is set up, everything just works:

```bash
# Make changes to core library
cd livetemplate
vim template.go

# Test in LVT (automatically uses your local changes)
cd ../lvt
go test ./...
go build

# Test in examples (automatically uses your local changes)
cd ../examples
./test-all.sh

# Test a specific example
cd counter
go run main.go
```

### Switching Between Local and Published

```bash
# Use local versions (workspace active)
./setup-workspace.sh

# Use published versions (workspace removed)
./setup-workspace.sh --clean
```

## How It Works

The `setup-workspace.sh` script:

1. Detects which repositories are present
2. Creates a `go.work` file listing all modules
3. Go commands automatically find and use `go.work`
4. Local modules take precedence over published versions

**Example `go.work` file:**
```go
go 1.25

use (
    ./livetemplate
    ./lvt
    ./examples/counter
    ./examples/chat
    ./examples/todos
    // ...
)
```

## Cross-Repository Testing

The core library has CI workflows that automatically test LVT and examples against pull requests:

- `.github/workflows/test.yml` - Basic tests
- `.github/workflows/cross-repo-test.yml` - Tests dependent repos

These workflows use replace directives (not workspaces) since they need to test specific branches.

## Alternative: Manual Replace Directives

If you prefer manual control or can't use workspaces (Go < 1.18), each repository has a setup script:

```bash
cd lvt
./scripts/setup-local-dev.sh        # Enable local core
./scripts/setup-local-dev.sh --undo # Revert to published

cd ../examples
./scripts/setup-local-dev.sh        # Enable local core + lvt
./scripts/setup-local-dev.sh --undo # Revert to published
```

These scripts modify `go.mod` files with replace directives.

## Contributing

See individual repository CONTRIBUTING.md files:

- [Core Library](livetemplate/CONTRIBUTING.md)
- [LVT CLI](lvt/CONTRIBUTING.md)
- [Examples](examples/CONTRIBUTING.md)
- [Client Library](client/README.md) (if present)

## Troubleshooting

### Workspace not working?

```bash
# Check Go version (need 1.18+)
go version

# Verify workspace exists
ls go.work

# Check which modules Go sees
go work use

# Verify module resolution
cd lvt
go list -m github.com/livetemplate/livetemplate
# Should show: /path/to/parent/livetemplate
```

### Want to temporarily disable workspace?

```bash
# Option 1: Remove workspace
./setup-workspace.sh --clean

# Option 2: Use GOWORK=off
GOWORK=off go test ./...  # Ignores workspace for this command
```

### Modules not being found?

Make sure directory structure matches:
- All repos must be siblings
- Repos must have `go.mod` files
- Run `./setup-workspace.sh` from parent directory

## Links

- **Core Library**: https://github.com/livetemplate/livetemplate
- **CLI Tool**: https://github.com/livetemplate/lvt
- **Examples**: https://github.com/livetemplate/examples
- **Client**: https://github.com/livetemplate/client
- **Documentation**: https://docs.livetemplate.dev

## License

Each repository has its own license. See individual LICENSE files.
