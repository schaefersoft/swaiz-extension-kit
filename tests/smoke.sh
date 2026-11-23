#!/usr/bin/env bash
set -euo pipefail

kit="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$kit/bin:$PATH"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

export GIT_AUTHOR_NAME=smoke GIT_AUTHOR_EMAIL=smoke@example.invalid
export GIT_COMMITTER_NAME=smoke GIT_COMMITTER_EMAIL=smoke@example.invalid

failures=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1" >&2; failures=$((failures + 1)); }
expect() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$3', got '$2'"; fi
}

manifest() {
  mkdir -p "$1"
  printf 'apiVersion: aictl.io/v2\nkind: Extension\nname: %s\nversion: %s\n' "$2" "$3" > "$1/extension.yaml"
}

commit() {
  git add -A
  git commit -qm "$1"
}

echo "== single extension at the repository root"
single="$work/swaiz-demo"
mkdir -p "$single"
cd "$single"
git init -q -b release
git config core.autocrlf false
manifest . demo 0.1.0
echo "# demo" > README.md
commit "feat: initial"

expect "first release ships the manifest version" "$(swaiz-ext-release plan 2>/dev/null)" '[{"ext":".","name":"demo","version":"0.1.0"}]'

swaiz-ext-build . >/dev/null
if [ -f dist/dl/extensions/demo/0.1.0/demo-0.1.0.tar.gz ] && grep -q 'demo-0.1.0.tar.gz' dist/dl/extensions/demo/0.1.0/checksums.txt; then
  pass "bundle and checksums built although the directory is not named like the extension"
else
  fail "bundle missing"
fi
expect "bundle holds the manifest" "$(tar -tzf dist/dl/extensions/demo/0.1.0/demo-0.1.0.tar.gz)" "extension.yaml"
rm -rf dist

git tag demo/v0.1.0
expect "nothing to release right after the tag" "$(swaiz-ext-release plan 2>/dev/null)" "[]"

mkdir -p .github/workflows
echo "on: push" > .github/workflows/ci.yaml
commit "feat: add ci"
expect "changes under .github do not release" "$(swaiz-ext-release plan 2>/dev/null)" "[]"

echo "fixed" >> README.md
commit "fix: typo"
expect "fix bumps the patch version" "$(swaiz-ext-release plan 2>/dev/null)" '[{"ext":".","name":"demo","version":"0.1.1"}]'

echo "more" >> README.md
commit "feat: more"
expect "feat bumps the minor version" "$(swaiz-ext-release plan 2>/dev/null)" '[{"ext":".","name":"demo","version":"0.2.0"}]'

echo "break" >> README.md
commit "feat!: break"
expect "breaking change bumps the major version" "$(swaiz-ext-release plan 2>/dev/null)" '[{"ext":".","name":"demo","version":"1.0.0"}]'

echo "== several extensions in one repository"
multi="$work/extensions"
mkdir -p "$multi"
cd "$multi"
git init -q -b release
git config core.autocrlf false
manifest alpha alpha 0.1.0
manifest beta beta 0.3.0
manifest .example example 1.0.0
commit "feat: initial"

expect "every extension is planned, dot directories are skipped" "$(swaiz-ext-release plan 2>/dev/null)" '[{"ext":"alpha","name":"alpha","version":"0.1.0"},{"ext":"beta","name":"beta","version":"0.3.0"}]'
expect "ONLY limits the plan" "$(ONLY=beta swaiz-ext-release plan 2>/dev/null)" '[{"ext":"beta","name":"beta","version":"0.3.0"}]'

git tag alpha/v0.1.0
git tag beta/v0.3.0
echo "x" > beta/README.md
commit "fix(beta): x"
expect "only the changed extension is planned" "$(swaiz-ext-release plan 2>/dev/null)" '[{"ext":"beta","name":"beta","version":"0.3.1"}]'

swaiz-ext-build alpha >/dev/null
if [ -f dist/dl/extensions/alpha/0.1.0/alpha-0.1.0.tar.gz ]; then pass "subdirectory bundle built"; else fail "subdirectory bundle missing"; fi

manifest gamma delta 0.1.0
if swaiz-ext-build gamma >/dev/null 2>&1; then
  fail "a subdirectory named unlike its extension must be rejected"
else
  pass "a subdirectory named unlike its extension is rejected"
fi

if swaiz-ext-build-images alpha >/dev/null; then pass "no services/ means no images"; else fail "build-images without services/"; fi

echo "== own images with a GPU build"
stub="$work/stub"
mkdir -p "$stub"
cat > "$stub/docker" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$DOCKER_LOG"
if [ "$1" = save ]; then printf 'image %s' "$2"; fi
STUB
chmod +x "$stub/docker"
export DOCKER_LOG="$work/docker.log"

gpu="$work/swaiz-gpu"
mkdir -p "$gpu/services/asr" "$gpu/services/api"
cd "$gpu"
git init -q -b release
git config core.autocrlf false
gpu_manifest() {
  cat > extension.yaml <<YAML
apiVersion: aictl.io/v2
kind: Extension
name: demo
version: 0.4.0
services:
  asr:
$1
    resources: { gpu: optional }
  api:
    image: demo-api:\${version}
YAML
}
gpu_manifest "    image: demo-asr:\${version}
    gpuImage: demo-asr:\${version}-gpu   # CUDA build"
echo "FROM scratch" > services/asr/Dockerfile
echo "FROM scratch" > services/api/Dockerfile
commit "feat: images"

: > "$DOCKER_LOG"
if PATH="$stub:$PATH" swaiz-ext-build-images . >/dev/null; then pass "images with a GPU build are built"; else fail "build-images with a gpuImage"; fi
expect "the GPU build is tagged as the manifest names it" "$(grep -c -e '-t demo-asr:0.4.0-gpu ' "$DOCKER_LOG")" "1"
expect "only the GPU build is built with VARIANT=gpu" "$(grep -e '--build-arg VARIANT=gpu' "$DOCKER_LOG" | grep -c -e '-t demo-asr:0.4.0-gpu ')" "1"
expect "the CPU builds get no variant" "$(grep -c -e '--build-arg' "$DOCKER_LOG")" "1"
expect "one tarball per build" "$(find images -type f -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ')" "demo-api-0.4.0.image.tar.gz demo-asr-0.4.0.gpu.image.tar.gz demo-asr-0.4.0.image.tar.gz "

PATH="$stub:$PATH" swaiz-ext-build . >/dev/null
expect "the bundle carries the GPU build next to the CPU one" \
  "$(tar -tzf dist/dl/extensions/demo/0.4.0/demo-0.4.0.tar.gz | grep '^images/' | LC_ALL=C sort | tr '\n' ' ')" \
  "images/ images/demo-api-0.4.0.image.tar.gz images/demo-asr-0.4.0.gpu.image.tar.gz images/demo-asr-0.4.0.image.tar.gz "
rm -rf dist images

gpu_manifest "    image: demo-asr:\${version}
    gpuImage: demo-asr:0.4.0-gpu"
if PATH="$stub:$PATH" swaiz-ext-build-images . >/dev/null 2>&1; then
  fail "a gpuImage without \${version} must be rejected"
else
  pass "a gpuImage without \${version} is rejected"
fi

gpu_manifest "    { image: demo-asr:\${version}, gpuImage: demo-asr:\${version}-gpu }"
if PATH="$stub:$PATH" swaiz-ext-build-images . >/dev/null 2>&1; then
  fail "a gpuImage in flow style must be rejected rather than silently not built"
else
  pass "a gpuImage in flow style is rejected"
fi

gpu_manifest "    image: demo-asr:\${version}
    gpuImage: quay.io/vendor/asr-cuda:1.0"
: > "$DOCKER_LOG"
PATH="$stub:$PATH" swaiz-ext-build-images . >/dev/null
expect "a third-party gpuImage is pulled at install, not built" "$(grep -c -e '--build-arg' "$DOCKER_LOG")" "0"
rm -rf images

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
