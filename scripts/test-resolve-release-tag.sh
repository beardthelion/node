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

release_workflow="$repo_root/.github/workflows/release.yml"
actual_resolver_steps="$test_tmp/actual-resolver-steps"
expected_resolver_steps="$test_tmp/expected-resolver-steps"

# Pin each resolver step and the checkout step that supplies its script. Any
# change to one of these reviewed blocks must be reflected here deliberately.
awk '
  function emit_step() {
    if (in_step && (is_rel || is_workflow_scripts_checkout)) {
      printf "job=%s\n%s", job, step
    }
    in_step = 0
    is_rel = 0
    is_workflow_scripts_checkout = 0
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
        run: |
          set -euo pipefail
          scripts/resolve-release-tag.sh "${DISPATCH_TAG:-$RELEASE_TAG}"

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
        run: |
          set -euo pipefail
          scripts/resolve-release-tag.sh "${DISPATCH_TAG:-$RELEASE_TAG}"

EOF

if ! cmp "$expected_resolver_steps" "$actual_resolver_steps"; then
  printf '%s\n' \
    "release workflow resolver steps differ from the three reviewed blocks" >&2
  diff -u "$expected_resolver_steps" "$actual_resolver_steps" >&2 || true
  exit 1
fi

# Every job that publishes to an external registry must declare the protected
# environment that gates it. workflow_dispatch runs the selected ref's YAML, so
# the environment's deployment-branch rule is the control that keeps a dispatch
# from a non-main ref out of npm and ghcr.
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
docker=release
docker-manifest=release
npm-publish=release
EOF

if ! cmp "$expected_job_environments" "$actual_job_environments"; then
  printf '%s\n' \
    "release workflow publish jobs differ on their environment gate" >&2
  diff -u "$expected_job_environments" "$actual_job_environments" >&2 || true
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
