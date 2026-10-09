# Repository instructions

## Git and GitHub

- Verify the canonical checkout, applicable overrides, branch, origin, revision, index, and dirty files before Git changes. Preserve unrelated work; isolate conflicting work in a worktree.
- Use a focused codex/ branch for a reviewable change. Keep uncommitted work available for user review unless a commit is authorized.
- Commit, push, PR creation, merge, tag, release, deployment, visibility changes, and deletion require authorization covering the operation and target. Honor an existing scoped authorization; do not infer publication from implementation approval.
- Stage explicit paths or approved hunks, review the complete staged diff, and keep private evidence and secrets out of GitHub.
- Merge only after applicable checks and conversations are satisfied for the latest candidate revision. Preserve required checks and prefer merge commits over rebase or squash when compatible with repository rules.
- Pin external Actions to upstream-verified full commit SHAs. Keep PR jobs read-only except the scoped code-scanning upload permission; publishing jobs require the protected github-release environment.

## Repository workflow

- Follow CONTRIBUTING.md, SECURITY.md, and docs/release-verification.md.
- Preserve the five required main checks: Swift package tests; App build, UI tests, and layout; Real simulator end-to-end test; Release packaging; Analyze Swift.
- Run the applicable commands in CONTRIBUTING.md. Preserve warnings-as-errors, real simulator execution, UI tests, rendered layout checks, and release verification.
- Verify a successful Swift CodeQL analysis at the candidate revision. An older scan or successful Actions analysis does not validate new Swift code.
- Releases are version 1.x or later from main. Confirm the tag, ToolkitVersion.current, MARKETING_VERSION, and exact candidate revision before publishing.
- A v[1-9]* tag push starts release publication through .github/workflows/release.yml; obtain authorization covering publication before pushing it, and retain owner approval on github-release.
