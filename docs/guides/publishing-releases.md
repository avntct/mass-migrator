# Publishing Releases — Two-Repo Flow

> **Private repo** (source-of-truth): `git@github.com:avntct/go-migrator-v3.git`
> **Public mirror** (binaries + docs only): `git@github.com:avntct/mass-migrator.git`

This guide covers the manual-trigger release flow that builds platform binaries
from private and publishes them to public as a GitHub Release, while mirroring
curated docs (per `scripts/.publish-manifest`).

Two entry points — they do the same work and accept the same versioning inputs:

| Entry point | Where it runs | When to use |
|---|---|---|
| `scripts/publish-to-public.sh` | Your laptop | Day-to-day; quick iterations; offline development |
| `.github/workflows/publish-to-public.yml` | GitHub-hosted runner | Reproducible builds; auditable in CI; when laptop tooling drifts |

## What gets published

**To the public repo (mirrored content):**
- `docs/guides/` — operator + author guides
- `docs/marketing/` — public-facing storytelling
- `docs/cli-reference.md`, `docs/dialect-interface-reference.md`, `docs/transform-helpers-reference.md`
- `docs/reference/` — every mode + flag
- `docs/wizard/`, `docs/storyboard-andy-migration-crisis.md`, `docs/intro-article-parallel-migration.md`
- Root-level `SECURITY.md`, `CHANGELOG.md`, `CONTRIBUTING.md`, `LICENSE`, `CLAUDE.md`
- `docs/marketing/github-homepage.md` → `README.md` (aliased)

**To the public GitHub Release (binary artifacts):**
- `mass-migrator_X.Y.Z_linux_amd64`
- `mass-migrator_X.Y.Z_linux_arm64`
- `mass-migrator_X.Y.Z_darwin_amd64`
- `mass-migrator_X.Y.Z_darwin_arm64`
- `mass-migrator_X.Y.Z_windows_amd64.exe`
- `checksums.txt` (SHA-256 of every binary)
- Cosign `.sig` + `.pem` files (when GoReleaser+cosign are available)

**Never pushed to public:** `internal/`, `cmd/`, `pkg/`, `tests/`, `docs/plans/`, `docs/sors-reports/`, `docs/archived/`, `.full-review/`, `graphify-out/`, `.github/`, `scripts/`. Edit `scripts/.publish-manifest` if the policy changes.

## Local flow — `scripts/publish-to-public.sh`

### Prerequisites

```
brew install gh jq goreleaser cosign
# OR
sudo apt install gh jq && go install github.com/goreleaser/goreleaser/v2@latest
```

You also need:

- A clean working tree on the private repo (or pass `--allow-dirty` if you really mean it)
- `gh auth status` showing logged-in for both `avntct/go-migrator-v3` AND `avntct/mass-migrator`
- SSH key access to both repos (`git@github.com:...` URLs)

### Common invocations

```bash
# Patch bump (e.g. 3.0.2 → 3.0.3); standard 5-platform build; full publish
./scripts/publish-to-public.sh --bump patch

# Explicit version (overrides bump)
./scripts/publish-to-public.sh --version 3.1.0

# Minor bump; dry-run first to see plan
./scripts/publish-to-public.sh --bump minor --dry-run
# (Inspect output, then run again without --dry-run.)

# Build + tag locally, do NOT push (for inspection)
./scripts/publish-to-public.sh --bump patch --skip-push

# Reuse already-built artifacts in dist/
./scripts/publish-to-public.sh --bump patch --skip-build

# Pre-release (marked as such on GitHub)
./scripts/publish-to-public.sh --version 3.1.0-rc.1 --prerelease

# Custom release notes file
./scripts/publish-to-public.sh --version 3.1.0 --notes ./release-notes-3.1.0.md
```

### What the script does, in order

1. Validates prerequisites (`git`, `gh`, `go`, `jq`; warns if `goreleaser`/`cosign` missing).
2. Verifies the private working tree is clean (unless `--allow-dirty`).
3. Reads the latest `vX.Y.Z` tag and computes the next version.
4. Builds binaries:
   - Uses GoReleaser snapshot mode if available (re-uses `.goreleaser.yml` matrix + cosign signing).
   - Falls back to a plain `go build` loop over the 5 standard platforms.
5. Writes `dist/checksums.txt` (SHA-256 of every binary).
6. Tags the private repo with `vX.Y.Z`.
7. Shallow-clones the public repo to a temp directory.
8. Walks `scripts/.publish-manifest` and copies each entry to the public clone.
9. Writes a `VERSION` file and prepends a release marker comment to public `README.md`.
10. Commits + tags in the public clone.
11. (Unless `--skip-push`) Pushes the private tag and the public main + tag.
12. Creates a GitHub Release on the public repo via `gh release create`, attaching all binaries + checksums.
13. Cleans up temp directories on exit.

### Recovering from a partial failure

If the script fails partway through, two scenarios:

| Failure point | Recovery |
|---|---|
| Before tagging private | Just re-run. Nothing pushed yet. |
| After tagging private, before push | `git tag -d vX.Y.Z` to remove the local tag, then re-run. |
| After push, before release create | Re-run with the same `--version X.Y.Z`. Tagging will fail (tag exists) — pass `--skip-build --version X.Y.Z` and the script will skip to the release-create step. (If that doesn't work cleanly, manually run the `gh release create` command shown in the error.) |
| Release created with wrong content | Delete the release via `gh release delete vX.Y.Z --repo avntct/mass-migrator`, then re-run. |

## CI flow — `.github/workflows/publish-to-public.yml`

### One-time setup

1. **Create a deploy key or PAT for the public repo:**
   - GitHub Settings → Developer settings → Personal access tokens (fine-grained)
   - Repository access: only `avntct/mass-migrator`
   - Permissions: `contents: write`, `metadata: read`
   - Copy the token

2. **Add it as a secret on the private repo:**
   - `avntct/go-migrator-v3` → Settings → Secrets and variables → Actions
   - New repo secret: `PUBLIC_REPO_TOKEN` = the token from step 1

3. **(Optional) Add a deploy key for SSH push:**
   - Generate `ssh-keygen -t ed25519 -f /tmp/mm-publish -N ""`
   - Add the public key (`.pub`) to `avntct/mass-migrator` → Settings → Deploy keys with **write access enabled**
   - Add the private key as secret `PUBLIC_REPO_DEPLOY_KEY` on the private repo
   - Without this, the script clones via HTTPS using the PAT — that also works.

4. **(Optional) Override the public repo URL via repo variable:**
   - `avntct/go-migrator-v3` → Settings → Secrets and variables → Actions → Variables
   - New variable: `PUBLIC_REPO` = `git@github.com:avntct/mass-migrator.git`
   - The workflow falls back to that URL if the variable is unset.

### Triggering a release

1. Go to **Actions tab** on the private repo
2. Pick **"Publish to public repo"** from the left sidebar
3. Click **Run workflow**
4. Fill in inputs:
   - **bump**: patch / minor / major (default patch)
   - **version**: explicit X.Y.Z to override bump
   - **dry_run**: tick to preview without pushing
   - **prerelease**: tick for RC builds
5. Click the green **Run workflow** button

The workflow runs for ~5-10 min depending on build matrix completion. The summary appears in the workflow's "Summary" tab with the checksums + version that was published.

### What the workflow does differently from local

- Always uses GoReleaser (installed by the workflow)
- Always uses Cosign (installed by the workflow)
- Always uploads `dist/` as a build artifact (retention 14 days) so you can inspect build outputs even if the publish step failed
- Git author is `github-actions[bot]` instead of your local identity

## Version bump rules

The script reads the latest `vX.Y.Z` tag (excluding pre-releases) from `git tag` and bumps accordingly:

| Bump type | Effect | Example |
|---|---|---|
| `patch` | Increment patch | `3.0.2` → `3.0.3` |
| `minor` | Increment minor; reset patch | `3.0.2` → `3.1.0` |
| `major` | Increment major; reset minor + patch | `3.0.2` → `4.0.0` |
| `--version X.Y.Z` | Use literal version | Whatever you specify |

If no `vX.Y.Z` tag exists, the script bumps from `0.0.0` (so `--bump patch` would give you `0.0.1`).

### Pre-release versions

For RC / beta / alpha releases, pass `--version X.Y.Z-tag.N`:

```
./scripts/publish-to-public.sh --version 3.1.0-rc.1 --prerelease
```

The `--prerelease` flag marks the GitHub Release as a pre-release (so it's hidden from the "Latest release" badge on the public repo).

## Editing the publish manifest

The list of paths that get mirrored lives at `scripts/.publish-manifest`. Edit it whenever you add new public-facing documentation. The format is one path per line:

```
# Comment lines start with #
# Blank lines are skipped

# Same path on both repos:
docs/guides/

# Aliased (different destination path):
docs/marketing/github-homepage.md => README.md
```

Source paths that don't exist in private at publish time are skipped with a warning (not an error) — useful when paths come and go between releases.

## Verifying a published release

Binaries are Cosign-signed (when GoReleaser ran). Customer verification:

```bash
# Download the binary + signature + cert
gh release download v3.0.3 --repo avntct/mass-migrator \
  --pattern 'mass-migrator_3.0.3_linux_amd64*'

# Verify
cosign verify-blob \
  --certificate mass-migrator_3.0.3_linux_amd64.pem \
  --signature mass-migrator_3.0.3_linux_amd64.sig \
  --certificate-identity-regexp '^https://github\.com/avntct/go-migrator-v3/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  mass-migrator_3.0.3_linux_amd64
```

Document this verification flow in the public `SECURITY.md` so end-users know how to trust your releases.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `gh CLI not authenticated` | Local `gh` not logged in | `gh auth login` |
| `gh release create failed` | PAT lacks `contents: write` on public repo | Regenerate the token with the right scope |
| `failed to clone public repo` | SSH key not authorized, or HTTPS PAT missing | Add SSH key to public repo OR use HTTPS URL with PAT in env |
| `Tag vX.Y.Z already exists locally` | Previous run partial; tag survived | `git tag -d vX.Y.Z` and re-run |
| Workflow dispatch input "version" missing | UI didn't pass through | Use `--bump` instead, or run locally |
| Binaries missing from release | Build failed silently | Check `dist/goreleaser.log` (uploaded as workflow artifact) |
| Public repo commit has unrelated changes | Someone else pushed to public main between clone and push | Re-run; the script does a fresh shallow clone each time |

## Convention: same tag on both repos

The script tags BOTH repos with the same `vX.Y.Z` value. This means:

- `git log --tags` on private shows the release point in source history
- `git log --tags` on public shows the mirror commit
- `gh release view vX.Y.Z --repo avntct/mass-migrator` is the canonical artifact location

If you want different tag prefixes (e.g. `src-v3.0.3` on private, `v3.0.3` on public), edit the `NEXT_TAG` assignment in the script. The default same-tag convention is recommended for clarity.

---

## Quick reference

```
# Daily flow
./scripts/publish-to-public.sh --bump patch

# Before hitting publish
./scripts/publish-to-public.sh --bump patch --dry-run

# Recovery
git tag -d vX.Y.Z                  # delete local tag
gh release delete vX.Y.Z --repo avntct/mass-migrator   # delete remote release
```

See also:

- `scripts/.publish-manifest` — the mirrored-paths list
- `.goreleaser.yml` — the build matrix + Cosign signing config (reused by both flows)
- `.github/workflows/publish-to-public.yml` — the CI version of this script
- `SECURITY.md` — operator-facing verification documentation
