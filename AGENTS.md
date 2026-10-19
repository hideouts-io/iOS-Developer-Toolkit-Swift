# Repository workflow

- Follow CONTRIBUTING.md, SECURITY.md, and docs/release-verification.md.
- Preserve the five required main checks: Swift package tests; App build, UI tests, and layout; Real simulator end-to-end test; Release packaging; Analyze Swift.
- Run the applicable commands in CONTRIBUTING.md. Preserve warnings-as-errors, real simulator execution, UI tests, rendered layout checks, and release verification.
- Verify a successful Swift CodeQL analysis at the candidate revision. An older scan or successful Actions analysis does not validate new Swift code.
- Releases are version 1.x or later from main. Confirm the tag, ToolkitVersion.current, MARKETING_VERSION, and exact candidate revision before publishing.
- A v[1-9]* tag push starts release publication through .github/workflows/release.yml; obtain authorization covering publication before pushing it, and retain owner approval on github-release.
- Source extraction and analysis use read-only tokens with upload: never and upload-database: false. Separate upload-only jobs publish SARIF; Code scanning uploads must succeed for every configured language.

## GitHub delivery defaults

- Whenever necessary to complete requested work in this project, stage only the reviewed task paths or hunks, create coherent commits, push ordinary non-force updates to the verified GitHub repository, and create or update a pull request without asking for repeated confirmation. Use a focused `codex/` branch and a pull request for source or behavior changes. A specific user instruction to leave work uncommitted overrides this default.
- Use a draft pull request when a concrete implementation is ready for review but a named native, device, or hosted validation gate remains pending. Report the exact checks that ran and the remaining limits; a draft does not satisfy or bypass those gates.
- Before each commit or push, verify the repository, branch, remote, outgoing diff, staged paths, author identity, and applicable validation. Preserve unrelated staged, unstaged, and untracked work. Keep private evidence and local validation artifacts out of public commits and PRs.
- This default does not authorize merges, history rewriting, force pushes, branch deletion, tags, releases, deployment, protected publication approvals, repository or permission changes, broader app access, or unrelated external messages. Obtain explicit authorization for those operations.
