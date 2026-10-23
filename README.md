# swaiz-extension-kit

Build and release tooling for **swaiz extensions** — the add-ons that
`aictl` installs on top of the swaiz
platform. The kit turns an extension's source into a server-ready bundle and
publishes it as a GitHub Release, which the distribution server then pulls,
signs and serves to `aictl extension install`.

```
swaiz-extension-kit/
├── action.yml                         setup action: puts bin/ on PATH (optionally installs aictl)
├── bin/
│   ├── swaiz-ext-build                pack ONE extension → unsigned bundle in dist/
│   ├── swaiz-ext-build-images         build + save the extension's own service images
│   └── swaiz-ext-release              plan / build / publish, auto-versioned
├── notices/                           open-source notice generators (Docker build context)
├── tests/smoke.sh                     end-to-end check of the scripts
└── .github/workflows/
    ├── extension-check.yaml           reusable: lint + check.sh
    └── extension-release.yaml         reusable: plan → build → publish
```

New extensions start from
[`swaiz-extension-template`](https://github.com/schaefersoft/swaiz-extension-template),
which already wires everything below.

## Prerequisites

| Tool | Needed for |
|---|---|
| Linux, or Windows with WSL 2 | every script — they use GNU `stat`, `tar` and `sha256sum`; macOS's BSD tools don't fit |
| bash 4+, git, GNU coreutils, tar, gzip | every script |
| Docker 23 or newer (BuildKit) | `swaiz-ext-build-images` (named build contexts) and most `check.sh` |
| `aictl` — `curl -fsSL https://swaiz.ch/install \| sh` | `aictl extension lint` |
| `gh`, logged in | `swaiz-ext-release publish` — CI does this for you |
| python3 | serving `dist/` locally |

**On Windows, work inside WSL:**

- Clone into the WSL file system (`~/…`), not under `/mnt/c`.
- The repositories enforce LF line endings (`.gitattributes`), but an editor
  writing through `\\wsl$\…` can still save CRLF. A script then fails with
  `$'\r': command not found` or a syntax error in the middle of the file. Fix it
  with `sed -i 's/\r$//' <file>`.
- Commit from inside WSL. Git for Windows on a WSL path drops the executable
  bit (`mode change 100755 => 100644`), and the scripts then fail with
  `Permission denied`.

## Repository layouts

The kit supports both, detected from where `extension.yaml` lives:

| Layout | `extension.yaml` | Extension dir | Directory name |
|---|---|---|---|
| **One extension per repository** | at the repository root | `.` | free (`swaiz-monitor` may hold `name: monitor`) |
| **Several per repository** | in each top-level `<ext>/` | `<ext>` | must equal `name:`; dot directories are skipped |

In the single layout, changes under `.github/` do not trigger a release.

## Use it in an extension repository

`.github/workflows/ci.yaml`:

```yaml
name: ci
on:
  pull_request:
  workflow_dispatch:
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true
jobs:
  check:
    uses: schaefersoft/swaiz-extension-kit/.github/workflows/extension-check.yaml@v1
```

`.github/workflows/release.yaml`:

```yaml
name: release
on:
  push:
    branches: [release]
  workflow_dispatch:
permissions:
  contents: write
concurrency: release
jobs:
  release:
    uses: schaefersoft/swaiz-extension-kit/.github/workflows/extension-release.yaml@v1
    secrets: inherit
```

Both workflows accept an optional `runner` input; without it they use the
`RUNNER` variable and fall back to `ubuntu-latest`. The release workflow also
accepts `extension` to limit a multi-extension repository to one directory.
`HF_TOKEN`, when the repository has it as a secret, reaches image builds as a
BuildKit secret (see below).

Your own workflows can use the tools directly:

```yaml
- uses: schaefersoft/swaiz-extension-kit@v1
  with:
    install-aictl: "true"
- run: swaiz-ext-build .
```

## Versioning — computed from the commits

Every extension is versioned independently, and the version is **derived from
the commits**, not hand-edited:

```
commits touching the extension since its last tag
        │ derive the bump  (feat → minor · fix/… → patch · BREAKING / type! → major)
        ├─▶ writes  extension.yaml: version:
        ├─▶ git tag        <name>/v2.3.1
        ├─▶ GitHub Release "<name> v2.3.1"        (bundle attached)
        └─▶ server path    /dl/extensions/<name>/2.3.1/
```

- **Tags are `<name>/v<version>`** in both layouts. The distribution server
  recognises releases by exactly this form.
- **Version format is semver** (`MAJOR.MINOR.PATCH[-pre]`), enforced by
  `swaiz-ext-build`.
- **The version is computed.** `swaiz-ext-release` reads the
  [Conventional Commit](https://www.conventionalcommits.org) subjects of the
  commits that touched the extension since its last tag — `feat:` → minor, a
  `type!:` subject or `BREAKING CHANGE:` footer → major, anything else → patch —
  and writes the result into `version:` (and into any own service `image:` with a
  concrete tag; the usual `image: <name>-<svc>:${version}` follows the manifest
  version by itself). The bump is committed back with `[skip ci]`. A **first**
  release ships the version in the manifest as-is.
- **No changes, no release.** An extension with nothing new since its last tag
  is skipped.
- **Published versions are immutable.** The server rejects re-publishing an
  existing `<name>/<version>`; `latest.txt` is the semver-max the server
  computes, never "last uploaded".

`swaiz-ext-release` runs in three phases so CI can fan out without push races;
only `publish` writes to git:

```sh
swaiz-ext-release plan                      # JSON matrix of extensions with unreleased changes
swaiz-ext-release build   <ext> <version>   # bundle + images into dist/, no git writes
swaiz-ext-release publish <ext> <version>   # commit bump, tag, push --atomic, GitHub Release
swaiz-ext-release                           # all three, serially (local use)
```

## Service images

An extension's **own** service images (a `services/<svc>/Dockerfile`) are built
by `swaiz-ext-build-images` as `<name>-<svc>:<version>` for `linux/amd64` and
`docker save`d — there is no container registry. An image up to 50 MB rides
**inside** the bundle; a larger one ships as a **sibling** artifact next to it,
listed in the same `checksums.txt` and fetched separately by aictl (the bundle
download is capped at 200 MiB, a sibling image at 8 GiB). `swaiz-ext-build`
fails and deletes the bundle when it exceeds 200 MiB packed or 2 GiB unpacked,
since aictl could not install it. GitHub rejects release assets over 2 GiB;
`swaiz-ext-release build` stops before anything is tagged.

Third-party images (no Dockerfile in the repository) are referenced from their
public registry, pinned by digest, and pulled at install.

Every own image carries its open-source notices under `/licenses/`. The
generators in `notices/` reach the Dockerfiles as an extra build context named
`notices`; a manual `docker build` needs
`--build-context notices=<kit>/notices`.

A gated download at build time (e.g. model weights) takes `HF_TOKEN` as a
BuildKit secret: Dockerfiles opt in via `RUN --mount=type=secret,id=hf_token …`.

## Signing & trust

Bundles are **signed by the distribution server**, not in CI.
`swaiz-ext-build` produces only `<name>-<version>.tar.gz` + `checksums.txt`
(plus any sibling image tarballs); when the server pulls the GitHub Release it
verifies the checksums and signs `checksums.txt` with the key whose **public**
half is embedded in `aictl`. `aictl extension install` then verifies that
signature before unpacking and running anything as root.

That private key is the root of trust for both licenses and extension
integrity, so it lives in exactly one place (the server) and never touches CI.
CI only needs the repository's own `GITHUB_TOKEN`.

## Build & test locally

```sh
git clone git@github.com:schaefersoft/swaiz-extension-kit.git ~/swaiz-extension-kit
export PATH="$HOME/swaiz-extension-kit/bin:$PATH"

cd my-extension
aictl extension lint .                   # manifest validation, offline
bash check.sh                            # the extension's own checks
swaiz-ext-build-images .                 # own service images → images/
swaiz-ext-build .                        # → dist/dl/extensions/<name>/<version>/
(cd dist && python3 -m http.server 8080) # serve the /dl tree like the real server
```

In a dev build of aictl, set `license.serverURL: http://localhost:8080`, then
`aictl extension install <name>`. A locally built bundle is **unsigned**, so a
release `aictl` refuses it. Dev builds of aictl are internal; without one, test
the real, server-signed release on a test node instead.

## Troubleshooting

| Message or symptom | Meaning | What to do |
|---|---|---|
| `! <branch> moved under <ext>/ while <name>@<version> was building` | Someone pushed to the extension while the release was building. Nothing was tagged. | Nothing. The run that push started releases the newer state. |
| `= <name>/v<version> already exists — skipping publish` | A re-run of a release that already went out. | Nothing. |
| `! <name>/v<version> already exists — version conflict, check the manifest` | First release, but the `version:` in the manifest is already tagged. | Raise `version:` in the manifest. |
| `version '…' is not semver` | `version:` is not `MAJOR.MINOR.PATCH[-pre]`. | Fix the manifest. |
| `manifest name '…' != directory '…'` | Several extensions per repository: directory and `name:` differ. | Rename one of them. |
| `… überschreitet GitHubs 2-GiB-Asset-Limit` | A sibling image is over GitHub's 2 GiB limit for release assets. Nothing was tagged. | Slim the image: drop build tools, and download model weights on first start into a volume instead of baking them in. |
| `<name>-<version>.tar.gz is … MiB packed and … MiB unpacked` | The bundle exceeds what aictl downloads (200 MiB) or unpacks (2 GiB). | Move large files out of the bundle. Images over 50 MB already ship as siblings. |
| `referenced file(s) missing` from `aictl extension lint` | A hook, n8n workflow, migration or seed named in the manifest is not in the repository. | Add the file or fix the path. |
| `check.sh` fails in the release job | The release refuses to ship an unhealthy extension. Nothing was tagged. | Fix it on `dev` and merge again. |
| The bump push is rejected: `GH013` / `Changes must be made through a pull request` | A ruleset on `release` requires pull requests, but the release workflow pushes its version bump directly. | Protect `release` against deletion and force pushes only. |
| `unknown flag: --build-context` | Docker is too old for named build contexts. | Docker 23 or newer. |
| Tag exists, but the GitHub Release lacks assets | The upload failed after the tag was pushed. A re-run plans nothing, because the tag already marks the version as released. | Rebuild that version at its tag and upload by hand: `git switch --detach <name>/v<version>`, `swaiz-ext-release build <ext> <version>`, `gh release upload <name>/v<version> dist/dl/extensions/<name>/<version>/* --clobber`. |

## Changing the kit

1. Branch off `dev`, make the change, run `tests/smoke.sh` and
   `shellcheck bin/* tests/*.sh`.
2. Try the scripts against a real extension: in its repository, put your
   checkout first on the `PATH` (`export PATH="<kit>/bin:$PATH"`) and run
   `swaiz-ext-release plan` and `swaiz-ext-build .`.
3. For workflow changes: the reusable workflows load the scripts through
   `schaefersoft/swaiz-extension-kit@v1`. To try a branch from a test
   repository, call the workflow there with `@<branch>` and, on the branch,
   point the inner `uses: schaefersoft/swaiz-extension-kit@v1` lines at the
   branch as well. Set them back to `@v1` before merging.
4. Open a pull request into `release`; CI must be green.
5. Tag the release and move the major tag. Callers pin `v1`:

```sh
git switch release && git pull
git tag v1.2.0 && git tag -f v1 v1.2.0
git push origin v1.2.0 && git push -f origin v1
gh release create v1.2.0 --verify-tag --title v1.2.0 --notes "…"
```

Version tags (`vX.Y.Z`) are protected and can be neither moved nor deleted;
only `v1` moves. A breaking change to inputs, script names or the tag format
gets `v2`.

## License

MIT — see [LICENSE](LICENSE).
