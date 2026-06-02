# Contributing to Mass Migrator

Thank you for your interest in contributing to Mass Migrator! This document provides guidelines and instructions for contributing to the project.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [Code Style Guidelines](#code-style-guidelines)
- [Testing Guidelines](#testing-guidelines)
- [Commit Message Guidelines](#commit-message-guidelines)
- [Pull Request Process](#pull-request-process)
- [Reporting Issues](#reporting-issues)

## Code of Conduct

Please be respectful and constructive in all interactions. We aim to maintain a welcoming and inclusive community.

## Getting Started

### Prerequisites

- Go 1.25.7 or later (matches the version declared in `go.mod`)
- Git
- Access to target databases for testing (PostgreSQL, MySQL, etc.)
- (Optional) Docker for integration testing
- [`gofumpt`](https://github.com/mvdan/gofumpt) for formatting
- [`golangci-lint`](https://golangci-lint.run/) for static analysis (config in `.golangci.yml`)

### Fork and Clone

1. Fork the repository on GitHub
2. Clone your fork:

```bash
git clone https://github.com/YOUR_USERNAME/mass-migrator.git
cd mass-migrator
```

3. Add the upstream remote:

```bash
git remote add upstream https://github.com/massmigrator/mass-migrator.git
```

## Development Setup

### Install Dependencies

```bash
go mod download
```

### Build the Project

```bash
make build
```

### Run Tests

```bash
# Run all tests (already enables -race)
make test

# Short / unit tests only
make test-unit

# Integration tests (requires databases)
make test-integration

# Run tests with coverage
make test-coverage
```

### Development Workflow

1. Create a new branch for your work:

```bash
git checkout -b feature/your-feature-name
# or
git checkout -b fix/your-bug-fix
```

2. Make your changes following the code style guidelines

3. Write tests for your changes

4. Ensure all tests pass:

```bash
make test
```

5. Commit your changes with descriptive commit messages

6. Push to your fork:

```bash
git push origin feature/your-feature-name
```

7. Create a pull request

## Code Style Guidelines

### Go Conventions

We follow standard Go conventions as described in [Effective Go](https://golang.org/doc/effective_go.html):

- Use [`gofumpt`](https://github.com/mvdan/gofumpt) for formatting (a stricter superset of `gofmt`)
- Run [`golangci-lint`](https://golangci-lint.run/) for linting — the rule set in `.golangci.yml` is authoritative
- Run `go vet ./...` for the built-in static analyser
- Use meaningful variable names
- Export functions and types that need to be public
- Keep functions focused and concise

### Formatting

Use `gofumpt` (lang-version 1.25) before committing. Install once with:

```bash
go install mvdan.cc/gofumpt@latest
```

Then:

```bash
gofumpt -l .   # list files that would be reformatted
gofumpt -w .   # rewrite them in place
```

Imports must be ordered: stdlib, external, local (`github.com/massmigrator/mass-migrator`).

### Linting

Install `golangci-lint` once (see https://golangci-lint.run/welcome/install/),
then run the full suite locally:

```bash
golangci-lint run
```

`.golangci.yml` at the repository root is the single source of truth — CI runs
the same configuration, so passing locally should produce a clean CI run.

### Pre-commit checklist

```bash
gofumpt -l .             # check formatting
golangci-lint run        # run all lints (see .golangci.yml)
go test -race ./...      # run tests with race detector
go vet ./...             # static analysis
```

### Code Organization

- Follow the existing directory structure
- Keep related functionality in the same package
- Use internal packages for implementation details
- Export types and functions through `pkg/` when needed

### Documentation

- Document exported functions, types, and constants
- Use godoc comments
- Include usage examples in documentation
- Keep documentation up to date with code changes

Example:

```go
// Dialect represents a database dialect with specific SQL syntax and behaviors.
//
// A Dialect provides methods for generating dialect-specific SQL for
// common operations like placeholders, upserts, and type conversions.
type Dialect interface {
    // Placeholder returns the dialect-specific placeholder for the given index.
    // For example, PostgreSQL uses $1, $2, while MySQL uses ?.
    Placeholder(idx int) string

    // SupportsUpsert returns true if the dialect supports upsert operations.
    SupportsUpsert() bool
}
```

## Testing Guidelines

### Test Organization

- Place test files in the same package as the code they test
- Name test files with `_test.go` suffix
- Use table-driven tests for multiple test cases

### Writing Tests

```go
func TestPlaceholder(t *testing.T) {
    tests := []struct {
        name     string
        dialect  Dialect
        idx      int
        expected string
    }{
        {
            name:     "PostgreSQL placeholder",
            dialect:  PostgreSQLDialect{},
            idx:      1,
            expected: "$1",
        },
        {
            name:     "MySQL placeholder",
            dialect:  MySQLDialect{},
            idx:      1,
            expected: "?",
        },
    }

    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            got := tt.dialect.Placeholder(tt.idx)
            if got != tt.expected {
                t.Errorf("Placeholder() = %v, want %v", got, tt.expected)
            }
        })
    }
}
```

### Test Coverage

- Aim for >80% code coverage
- Focus on testing business logic and edge cases
- Mock external dependencies (databases, APIs)
- Use real databases for integration tests when appropriate

### Running Tests

```bash
# Run all tests
go test ./...

# Run specific test
go test -run TestPlaceholder ./internal/dialect

# Run with verbose output
go test -v ./...

# Run with coverage
go test -coverprofile=coverage.out ./...
go tool cover -html=coverage.out
```

### Integration Tests

Integration tests should:

- Use environment variables for database credentials
- Skip tests if databases are not available
- Clean up test data after completion
- Be tagged with `integration` build tag

```go
//go:build integration
// +build integration

func TestPostgreSQLIntegration(t *testing.T) {
    if os.Getenv("POSTGRESQL_URL") == "" {
        t.Skip("POSTGRESQL_URL not set")
    }
    // Integration test code
}
```

## Commit Message Guidelines

We follow [Conventional Commits](https://www.conventionalcommits.org) for all commit messages. This enables:

- Automated changelog generation via release-drafter
- Semantic versioning (major/minor/patch) via automated rules
- Cleaner git history and easier navigation

**Commit messages are validated automatically** — pull requests with non-compliant messages will fail the commitlint check.

### Format

```
<type>(<scope>): <subject>

<body>

<footer>
```

### Types

- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `style`: Code style changes (formatting, etc.)
- `refactor`: Code refactoring
- `test`: Test additions or changes
- `perf`: Performance improvements
- `build`: Changes to build configuration or scripts
- `ci`: Changes to CI/CD pipeline
- `chore`: Other changes (dependencies, tooling, etc.)

### Rules

- Type must be lowercase
- Subject line should be imperative, present tense ("add feature" not "added feature")
- Subject line should not end with a period
- Keep subject line under 50 characters when possible
- Reference issues: `Closes #123` or `Fixes #456` in the footer

### Examples

```
feat(dialect): add Netezza dialect support

Implement Netezza dialect with specific SQL syntax for:
- LIMIT/OFFSET clauses
- UPSERT operations
- Type conversions

Closes #123
```

```
fix(transform): handle null values in transform context

Previously, null values would cause panics when accessing
fields in transform scripts. Now return nil for null fields.

Fixes #456
```

### Release Notes

Commit types are automatically mapped to release notes via labels on pull requests:

- `feat` → Features section
- `fix` → Bug Fixes section
- `perf` → Performance section
- `security` → Security section
- `docs` → Documentation section
- `breaking` or labeled `major` → Breaking Changes section

For best results, use descriptive PR titles that follow the commit format, or add appropriate labels (`feature`, `fix`, `security`, etc.) to your PR.

## Pull Request Process

### Before Submitting

1. Ensure your code follows the style guidelines
2. Write/update tests for your changes
3. Run all tests and ensure they pass
4. Update documentation if needed
5. Clean up your commit history (squash related commits)

### Creating a Pull Request

1. Push your changes to your fork
2. Go to the GitHub repository
3. Click "New Pull Request"
4. Select your branch
5. Fill in the PR template:
   - Describe your changes
   - Reference related issues
   - Add screenshots for UI changes
   - List breaking changes

### PR Review Process

1. Automated checks will run (tests, linting)
2. Maintainers will review your code
3. Address review comments
4. Once approved, your PR will be merged

### After Merge

1. Delete your branch from your fork
2. Update your local repository:

```bash
git checkout main
git pull upstream main
```

## Reporting Issues

### Bug Reports

When reporting bugs, include:

- Clear description of the problem
- Steps to reproduce
- Expected behavior
- Actual behavior
- Environment (OS, Go version, database versions)
- Logs or error messages
- Minimal reproduction case if possible

### Feature Requests

When requesting features:

- Describe the use case
- Explain why the feature is needed
- Provide examples of how it would be used
- Consider if it fits the project scope

### Issue Labels

- `bug`: Bug reports
- `enhancement`: Feature requests
- `documentation`: Documentation issues
- `good first issue`: Good for newcomers
- `help wanted`: Community help needed

## Development Tips

### Useful Commands

```bash
# Format code (requires gofumpt — see Code Style Guidelines)
gofumpt -w .

# Run linter (requires golangci-lint — see Code Style Guidelines)
golangci-lint run

# Run all tests (race detector on)
make test

# Unit tests only
make test-unit

# Integration tests (requires databases)
make test-integration

# Coverage report
make test-coverage

# Static analysis
make vet

# Build all binaries
make build

# Clean build artifacts
make clean
```

### Debugging

- Use `delve` for debugging: `dlv debug ./cmd/mass-migrator`
- Enable debug logging with `--verbose` flag
- Use `--dry-run` to test without making changes

### Performance Profiling

```bash
# CPU profile
go test -cpuprofile=cpu.prof ./...
go tool pprof cpu.prof

# Memory profile
go test -memprofile=mem.prof ./...
go tool pprof mem.prof
```

## Questions?

- Check existing [Issues](https://github.com/massmigrator/mass-migrator/issues)
- Start a [Discussion](https://github.com/massmigrator/mass-migrator/discussions)
- Read the [Documentation](docs/)

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
