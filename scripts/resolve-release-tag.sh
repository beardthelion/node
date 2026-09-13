#!/usr/bin/env bash
set -euo pipefail
shopt -s extglob

tag="${1-}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT must be set}"

case "$tag" in
  ""|*[!A-Za-z0-9._-]*)
    printf '%s\n' "::error::release tag is empty or contains invalid characters"
    exit 1
    ;;
esac

# Right-anchored on purpose: v[0-9]* leaves the tail unbounded and accepts
# v1.2.3.4.5, v1_x, v1-any-branch-name, and bare v1. Every existing tag is
# plain vX.Y.Z (release-please, release-type: simple, no prerelease channel).
case "$tag" in
  v+([0-9]).+([0-9]).+([0-9])) ;;
  *)
    printf '%s\n' "::error::'$tag' does not look like a release tag (vX.Y.Z)"
    exit 1
    ;;
esac

printf '%s\n' "tag=$tag" >> "$GITHUB_OUTPUT"
printf '%s\n' "version=${tag#v}" >> "$GITHUB_OUTPUT"
