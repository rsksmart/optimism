# Releasing

Per-package releases follow the upstream Optimism convention: a git tag shaped
`<component>/v<semver>` triggers a build of that component's Docker image and
publishes a GitHub Release.

## Tag scheme

- Stable:    `op-node/v1.17.0`
- Prerelease: `op-node/v1.17.0-rc.1`, `op-deployer/v0.7.0-alpha.2`
- Fork-specific suffix: `op-node/v1.17.0-rsk.1` (any tag containing `-` is
  marked as a GitHub prerelease automatically)

The existing `ops/scripts/find_release_tag.sh` and
`ops/scripts/latest-versions.sh` already understand this scheme.

## Releasable components

The release whitelist lives in two places — keep them in sync if you add more:

- `.github/workflows/release.yml` (the `case "$component" in` block)
- `justfile`, recipe `release-build`

Current whitelist: `op-node`, `op-batcher`, `op-proposer`, `op-deployer`.

Adding a new component only requires that a target with the same name exists
in `docker-bake.hcl`.

## How to release

1. Land the changes on `rsk/pilot` (or whichever release branch you cut).
2. Tag and push:
   ```bash
   git tag op-node/v1.17.0-rsk.1
   git push origin op-node/v1.17.0-rsk.1
   ```
3. GitHub Actions does the rest:
   - `docker buildx bake <component>` multi-arch (`linux/amd64,linux/arm64`)
   - Pushes to `ghcr.io/<owner>/<component>:<version>`
   - Bakes `GIT_VERSION` / `GIT_COMMIT` / `GIT_DATE` into the binary
   - Creates a GitHub Release with auto-generated notes (prerelease if the
     version contains a `-`)

## Local dry-run

```bash
# Build and load into local docker (single arch):
just release-build op-node v1.17.0-rsk.1 linux/amd64

# Build multi-arch and push to GHCR:
PUSH=1 just release-build op-node v1.17.0-rsk.1
```

The recipe reads the GHCR owner from `remote.origin.url`; override with
`GHCR_OWNER=...` if needed.

## RC cycles

Mirror upstream:

1. Cut a release branch, e.g. `op-node/v1.17`, from `develop` (or `rsk/pilot`).
2. Push `op-node/v1.17.0-rc.1`, iterate with `-rc.2`, `-rc.3`, ...
3. When ready, push `op-node/v1.17.0` from the same branch tip.

## First-time setup

- Repo Settings → Actions → General → "Read and write permissions" for
  `GITHUB_TOKEN` (the workflow also declares `packages: write` explicitly).
- After the first push, flip the GHCR package's visibility to public if you
  want unauthenticated pulls.
