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

# Provenance, enforced only in CI where a token is present. The environment
# gate restricts which REF a dispatch may run from; this restricts which TAG
# the input may name: it must be a tag the release flow already published,
# pointing at a commit main already contains. Otherwise a write-access user
# could plant a v99.99.99 tag on unreviewed content and backfill-publish it.
if [ -n "${GH_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
  release_author="$(gh release view "$tag" --repo "$GITHUB_REPOSITORY" \
    --json author -q .author.login 2>/dev/null)" || {
    printf '%s\n' "::error::no GitHub release exists for tag $tag"
    exit 1
  }
  # A hand-created release on a valid tag does not qualify. Not a hard bound
  # (a workflow run can mint a bot-authored release), but it removes the
  # cheapest path to publishing attacker-uploaded release assets.
  if [ "$release_author" != "github-actions[bot]" ]; then
    printf '%s\n' "::error::release $tag was authored by $release_author, not the release automation"
    exit 1
  fi
  # Resolve through the fully-qualified tag ref to a commit SHA: an
  # unqualified name can resolve to a same-named branch and vouch for the
  # wrong commit, the same shadowing the refs/tags/ checkout prefix avoids.
  tag_commit="$(gh api "repos/$GITHUB_REPOSITORY/commits/refs/tags/$tag" -q .sha)"
  status="$(gh api "repos/$GITHUB_REPOSITORY/compare/main...$tag_commit" -q .status)"
  case "$status" in
    identical|behind) ;;
    *)
      printf '%s\n' "::error::tag $tag is not reachable from main (compare: $status)"
      exit 1
      ;;
  esac
fi

printf '%s\n' "tag=$tag" >> "$GITHUB_OUTPUT"
printf '%s\n' "version=${tag#v}" >> "$GITHUB_OUTPUT"
