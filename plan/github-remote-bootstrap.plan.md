# GitHub Remote Bootstrap

Status: Active

Branch: `chore/github-remote-bootstrap`

Milestone: `v0.3.1`

Dependencies: [macOS 26 release](macos26-release.plan.md), [Universal reading position](universal-reading-position.plan.md)

## Summary

Publish the existing local history as a public `zzqDeco/OneReader` repository
and make the documented branch, CI, release, and planning rules enforceable on
GitHub rather than leaving them as local conventions.

## User Behavior

- Contributors can discover the current product, plans, documentation, open
  work, and validation status from one public repository.
- Pull requests into `dev` and `main` receive one authoritative native
  validation signal, while ordinary topic pushes do not create duplicate runs.
- Releases remain unavailable until an annotated version tag is created from
  the exact protected `main` tip.

## Contracts/Migration

- Preserve every existing commit and branch without rewriting local history.
- Keep `main` as the default and release branch; use `dev` as the integration
  branch and require pull requests plus the hosted native validation check for
  both protected branches.
- Disable force pushes and branch deletion. Keep workflow permissions read-only
  except for the existing isolated Release publication job.
- Publish no credential, local Source, derived material, or Provider secret.
  The first public version intentionally has no software license until the owner
  makes that legal choice explicitly.

## Implementation

- Create the public repository without generated commits, then push the exact
  local `main`, `dev`, and bootstrap topic heads.
- Set the repository description, platform/reader topics, Issues and Projects;
  keep repository documentation in `doc/` instead of enabling a second wiki.
- Exercise the bootstrap topic through a real pull request into `dev`, then
  promote `dev` to `main` through a separate pull request after exact-head CI.
- Protect `main` and `dev` with strict GitHub Actions checks, pull requests,
  admin enforcement, and immutable history controls. Protect release tag names
  without bypassing the exact-main validation already owned by Release CI.
- Add a concise pull-request template, a public `v0.3.1` milestone, a dedicated
  OneReader project, and issues for the remaining license, physical iPad, and
  Xcode 27 stable-toolchain decisions.

## Test Plan

- Run the documentation index and whitespace checks before the first push.
- Observe `CI / Native validation` on the exact bootstrap PR head and again on
  the exact `dev -> main` promotion head.
- Query repository settings, branch protection, rulesets, milestone, project,
  issues, Actions runs, and final remote branch SHAs through the GitHub API.
- Distinguish hosted build proof from the already recorded physical-iPhone and
  local native runtime evidence.

## Acceptance Evidence

Pending creation and exact-head verification of the public GitHub repository.

## Non-goals

Choosing a software license, publishing a GitHub Release, creating a version
tag, notarizing binaries, App Store delivery, or claiming physical iPad
acceptance without a connected device.

## Delivery Checklist

- [ ] Public repository created without history rewrite
- [ ] Exact local branches pushed and default branch verified
- [ ] Bootstrap and promotion pull requests pass exact-head hosted CI
- [ ] `main` and `dev` branch protection verified
- [ ] Release tag rules and repository settings verified
- [ ] Milestone, project, and honest open backlog created
- [ ] Current-state documentation synchronized
- [ ] Branch merged into `dev`, then `dev` promoted into `main`
- [ ] Status changed to Delivered
