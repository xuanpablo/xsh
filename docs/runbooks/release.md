# Release runbook

Everything is automated; the only human step is the tag.

1. Merge to `main` with CI green.
2. `git tag vX.Y.Z && git push origin vX.Y.Z` - `release.yml` takes it from
   there: draft release, six targets (musl built in Alpine containers, macOS,
   Windows), archives, `sha256sums.txt`, then it flips the draft to published.
3. Smoke test a few minutes later: download from `releases/latest` and run
   `maki --version`.

## When it breaks

- **A build job failed.** Re-run it from the run page. Uploads use `--clobber`,
  so a re-run replaces stale archives, and the network steps already retry
  internally.
- **A re-run is not enough.** Delete the draft (`gh release delete vX.Y.Z`),
  then delete and re-push the tag:
  `git push origin :refs/tags/vX.Y.Z && git push origin vX.Y.Z`.
- **A published release is bad.** Do not edit it. Cut `vX.Y.Z+1`: the install
  scripts resolve `releases/latest`, so the bad one stops being served within
  minutes.
