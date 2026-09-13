#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
resolver="$repo_root/scripts/resolve-release-tag.sh"
test_tmp="$(mktemp -d)"
trap 'rm -r -- "$test_tmp"' EXIT

valid_output="$test_tmp/valid-output"
GITHUB_OUTPUT="$valid_output" "$resolver" "v1.2.3"

expected_output="$test_tmp/expected-output"
printf '%s\n' "tag=v1.2.3" "version=1.2.3" > "$expected_output"
cmp "$expected_output" "$valid_output"

newline_output="$test_tmp/newline-output"
newline_stdout="$test_tmp/newline-stdout"
newline_stderr="$test_tmp/newline-stderr"
if GITHUB_OUTPUT="$newline_output" "$resolver" $'v1.2.3\nname=owned' \
  > "$newline_stdout" 2> "$newline_stderr"
then
  printf '%s\n' "newline-containing release tag unexpectedly passed" >&2
  exit 1
fi
test ! -s "$newline_output"
grep -qxF "::error::release tag is empty or contains invalid characters" "$newline_stdout"
test ! -s "$newline_stderr"

empty_output="$test_tmp/empty-output"
if GITHUB_OUTPUT="$empty_output" "$resolver" ""; then
  printf '%s\n' "empty release tag unexpectedly passed" >&2
  exit 1
fi
test ! -s "$empty_output"

invalid_output="$test_tmp/invalid-output"
for invalid_tag in \
  "v1.2.3 tag" \
  "v1.2.3;name=owned" \
  "v1.2.3+build.5" \
  "release-1.2.3" \
  "v-1" \
  "vlatest" \
  "v" \
  "v1.2.3/../../x" \
  "V1.2.3" \
  "v1atest" \
  "v1.2.3.4.5" \
  "v1_x" \
  "v1-any-branch-name" \
  "v1" \
  "v1.2." \
  "v1..3"
do
  : > "$invalid_output"
  if GITHUB_OUTPUT="$invalid_output" "$resolver" "$invalid_tag"; then
    printf '%s\n' "invalid release tag unexpectedly passed: $invalid_tag" >&2
    exit 1
  fi
  test ! -s "$invalid_output"
done

# The resolver's provenance branch, exercised against a stubbed gh. With a
# token present the tag must name an existing GitHub release and its commit
# must already be reachable from main (compare status identical|behind).
# ahead/diverged or a missing release must fail closed: a write-access user
# could otherwise plant a vX.Y.Z tag on unreviewed content and backfill it.
stub_bin="$test_tmp/stub-bin"
mkdir -p "$stub_bin"
cat > "$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  api)
    printf '%s\n' "${STUB_STATUS:?STUB_STATUS unset}"
    ;;
  release)
    [ "${STUB_RELEASE_EXISTS:-0}" = "1" ]
    ;;
esac
STUB
chmod +x "$stub_bin/gh"

run_resolver_ci() {
  PATH="$stub_bin:$PATH" \
  GH_TOKEN=test-token \
  GITHUB_REPOSITORY=Gitlawb/node \
  STUB_STATUS="$1" STUB_RELEASE_EXISTS="$2" \
  GITHUB_OUTPUT="$test_tmp/prov-output" \
    "$resolver" "$3" >/dev/null 2>&1
}

if ! run_resolver_ci behind 1 v9.9.9; then
  printf '%s\n' "provenance: release tag reachable from main rejected" >&2
  exit 1
fi
if ! run_resolver_ci identical 1 v9.9.9; then
  printf '%s\n' "provenance: release tag at main tip rejected" >&2
  exit 1
fi
for bad_status in ahead diverged; do
  if run_resolver_ci "$bad_status" 1 v9.9.9; then
    printf '%s\n' "provenance: $bad_status tag unexpectedly passed" >&2
    exit 1
  fi
done
if run_resolver_ci behind 0 v9.9.9; then
  printf '%s\n' "provenance: tag with no GitHub release unexpectedly passed" >&2
  exit 1
fi

release_workflow="$repo_root/.github/workflows/release.yml"
actual_resolver_steps="$test_tmp/actual-resolver-steps"
expected_resolver_steps="$test_tmp/expected-resolver-steps"

# Pin each resolver step, the checkout step that supplies its script, and the
# two steps that publish to an external registry. Any change to one of these
# reviewed blocks must be reflected here deliberately.
awk '
  function emit_step() {
    if (in_step && (is_rel || is_workflow_scripts_checkout || is_manifest || is_npm_publish)) {
      printf "job=%s\n%s", job, step
    }
    in_step = 0
    is_rel = 0
    is_workflow_scripts_checkout = 0
    is_manifest = 0
    is_npm_publish = 0
    step = ""
  }

  /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
    emit_step()
    job = $0
    sub(/^  /, "", job)
    sub(/:[[:space:]]*$/, "", job)
    next
  }

  /^      - / {
    emit_step()
    in_step = 1
    is_workflow_scripts_checkout = ($0 ~ /^      - name:[[:space:]]*Check out workflow scripts[[:space:]]*$/)
    is_manifest = ($0 ~ /^      - name:[[:space:]]*Create and push multi-arch manifest[[:space:]]*$/)
    is_npm_publish = ($0 ~ /^      - name:[[:space:]]*Publish[[:space:]]*$/)
    step = $0 ORS
    next
  }

  in_step {
    step = step $0 ORS
    if ($0 ~ /^        id:[[:space:]]*rel[[:space:]]*$/) {
      is_rel = 1
    }
  }

  END {
    emit_step()
  }
' "$release_workflow" > "$actual_resolver_steps"

cat > "$expected_resolver_steps" <<'EOF'
job=docker
      - name: Check out workflow scripts
        uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
        with:
          persist-credentials: false

job=docker
      - name: Resolve release tag
        id: rel
        env:
          DISPATCH_TAG: ${{ inputs.docker_backfill_tag }}
          RELEASE_TAG: ${{ needs.release-please.outputs.tag_name }}
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          set -euo pipefail
          scripts/resolve-release-tag.sh "${DISPATCH_TAG:-$RELEASE_TAG}"
          # ghcr requires a lowercase repository path, and unlike metadata-action,
          # buildx's `--output name=` does no lowercasing — a mixed-case owner
          # makes the digest push fail with "invalid reference format".
          echo "image=ghcr.io/${GITHUB_REPOSITORY,,}" >> "$GITHUB_OUTPUT"

job=docker-manifest
      - name: Check out workflow scripts
        uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
        with:
          persist-credentials: false

job=docker-manifest
      - name: Resolve release tag
        id: rel
        env:
          DISPATCH_TAG: ${{ inputs.docker_backfill_tag }}
          RELEASE_TAG: ${{ needs.release-please.outputs.tag_name }}
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          set -euo pipefail
          scripts/resolve-release-tag.sh "${DISPATCH_TAG:-$RELEASE_TAG}"

job=docker-manifest
      - name: Create and push multi-arch manifest
        env:
          VERSION: ${{ steps.rel.outputs.version }}
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          set -euo pipefail
          # ghcr requires a lowercase repository path.
          IMAGE="ghcr.io/${GITHUB_REPOSITORY,,}"
          MAJOR_MINOR="${VERSION%.*}"
          # The docker matrix pushes one digest per arch leg; anything else is
          # a broken set, not a smaller multi-arch image.
          count="$(find /tmp/digests -maxdepth 1 -type f | wc -l)"
          if [ "$count" -ne 2 ]; then
            echo "::error::expected 2 arch digests in /tmp/digests, found $count"
            exit 1
          fi
          digests=""
          for f in /tmp/digests/*; do
            d="$(basename "$f")"
            case "$d" in
              *[!0-9a-f]*)
                echo "::error::digest filename is not lowercase sha256 hex: $d"
                exit 1
                ;;
            esac
            if [ "${#d}" -ne 64 ]; then
              echo "::error::digest is not 64 hex chars: $d"
              exit 1
            fi
            digests="$digests $IMAGE@sha256:$d"
          done
          # The immutable tag always publishes. The moving tags only advance:
          # a backfill of anything but the newest release leaves :latest and
          # :X.Y pointing at the newer image.
          # shellcheck disable=SC2086
          docker buildx imagetools create -t "$IMAGE:$VERSION" $digests
          latest_tag="$(gh release view --json tagName -q .tagName)"
          latest_version="${latest_tag#v}"
          newest="$(printf '%s\n%s\n' "$latest_version" "$VERSION" | sort -V | tail -1)"
          if [ "$newest" = "$VERSION" ]; then
            # shellcheck disable=SC2086
            docker buildx imagetools create \
              -t "$IMAGE:$MAJOR_MINOR" \
              -t "$IMAGE:latest" \
              $digests
          else
            echo "::notice::$VERSION is older than $latest_tag; not moving :$MAJOR_MINOR or :latest"
          fi
          docker buildx imagetools inspect "$IMAGE:$VERSION"

job=npm-publish
      - name: Check out workflow scripts
        uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
        with:
          persist-credentials: false

job=npm-publish
      - name: Resolve release tag
        id: rel
        env:
          DISPATCH_TAG: ${{ inputs.npm_backfill_tag }}
          RELEASE_TAG: ${{ needs.release-please.outputs.tag_name }}
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          set -euo pipefail
          scripts/resolve-release-tag.sh "${DISPATCH_TAG:-$RELEASE_TAG}"

job=npm-publish
      - name: Publish
        env:
          VERSION: ${{ steps.rel.outputs.version }}
        run: |
          set -euo pipefail
          # No token: npm exchanges this job's GitHub OIDC identity with the
          # registry (trusted publishing); provenance is attested automatically.
          # Platform packages first, then the wrapper (so its optionalDependencies resolve).
          # Skip versions already on the registry so a rerun after a partial publish
          # is idempotent instead of erroring on the first existing package.
          # npm publish moves the latest dist-tag to whatever it publishes, so a
          # backfilled older version would hand :latest to stale code. Publish
          # those under the backfill dist-tag instead.
          registry_latest="$(npm view @gitlawb/gl dist-tags.latest 2>/dev/null || true)"
          dist_tag="latest"
          if [ -n "$registry_latest" ] && \
             [ "$VERSION" != "$(printf '%s\n%s\n' "$registry_latest" "$VERSION" | sort -V | tail -1)" ]; then
            dist_tag="backfill"
            echo "::notice::$VERSION is older than registry latest $registry_latest; publishing under dist-tag backfill"
          fi
          for pkg in gl-darwin-arm64 gl-darwin-x64 gl-linux-arm64 gl-linux-x64 gl; do
            name="@gitlawb/$pkg"
            if npm view "$name@$VERSION" version >/dev/null 2>&1; then
              echo "==> $name@$VERSION already published, skipping"
              continue
            fi
            echo "==> npm publish $name@$VERSION (dist-tag $dist_tag)"
            npm publish "npm/packages/$pkg" --provenance --access public --tag "$dist_tag"
          done

EOF

if ! cmp "$expected_resolver_steps" "$actual_resolver_steps"; then
  printf '%s\n' \
    "release workflow resolver steps differ from the three reviewed blocks" >&2
  diff -u "$expected_resolver_steps" "$actual_resolver_steps" >&2 || true
  exit 1
fi

# Every job declares the protected environment, not only the registry publish
# jobs: workflow_dispatch runs the selected ref's YAML, so the environment's
# deployment-branch rule is the control that keeps a dispatch of unmodified
# YAML on a non-main ref from reaching any step in this workflow.
actual_job_environments="$test_tmp/actual-job-environments"
awk '
  /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
    job = $0
    sub(/^  /, "", job)
    sub(/:[[:space:]]*$/, "", job)
  }
  /^    environment:[[:space:]]*/ {
    env = $0
    sub(/^    environment:[[:space:]]*/, "", env)
    gsub(/[[:space:]]/, "", env)
    print job "=" env
  }
' "$release_workflow" > "$actual_job_environments"

expected_job_environments="$test_tmp/expected-job-environments"
cat > "$expected_job_environments" <<'EOF'
release-please=release
sync-release-lock=release
docker=release
docker-manifest=release
release-binaries=release
npm-publish=release
homebrew-bump=release
web-sync=release
EOF

if ! cmp "$expected_job_environments" "$actual_job_environments"; then
  printf '%s\n' \
    "release workflow publish jobs differ on their environment gate" >&2
  diff -u "$expected_job_environments" "$actual_job_environments" >&2 || true
  exit 1
fi

# Every checkout of a release tag must qualify the ref as refs/tags/... :
# actions/checkout resolves an unqualified ref as a branch before a tag, so a
# same-named branch would shadow the release tag and the release would build
# from unreviewed branch content.
if grep -nE 'ref:[[:space:]]*\$\{\{[^}]*tag[^}]*\}\}' "$release_workflow" \
  | grep -v 'refs/tags/'; then
  printf '%s\n' "unqualified release-tag checkout ref (branch shadows tag)" >&2
  exit 1
fi

# The OIDC publish path must run on an exact npm version, not a range. A range
# operator resolves to whatever the registry serves that day, which is the same
# mutable-dependency shape the action pins exist to prevent.
npm_install_specs="$test_tmp/npm-install-specs"
grep -o 'npm install -g npm@[^ "]*' "$release_workflow" | sort -u \
  > "$npm_install_specs"
while IFS= read -r spec; do
  if ! grep -qE '^npm install -g npm@[0-9]+\.[0-9]+\.[0-9]+$' <<<"$spec"; then
    printf '%s\n' \
      "npm install spec is not an exact pinned version: $spec" >&2
    exit 1
  fi
done < "$npm_install_specs"

printf '%s\n' "release tag validation tests passed"
