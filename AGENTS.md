# Repository workflow

- Follow CONTRIBUTING.md, SECURITY.md, and docs/release-verification.md.
- Preserve the five required main checks: Swift package tests; App build, UI tests, and layout; Real simulator end-to-end test; Release packaging; Analyze Swift.
- Run the applicable commands in CONTRIBUTING.md. Preserve warnings-as-errors, real simulator execution, UI tests, rendered layout checks, and release verification.
- Verify a successful Swift CodeQL analysis at the candidate revision. An older scan or successful Actions analysis does not validate new Swift code.
- Releases are version 1.x or later from main. Confirm the tag, ToolkitVersion.current, MARKETING_VERSION, and exact candidate revision before publishing.
- A v[1-9]* tag push starts release publication through .github/workflows/release.yml; obtain authorization covering publication before pushing it, and retain owner approval on github-release.
- Source extraction and analysis use read-only tokens with upload: never and upload-database: false. Separate upload-only jobs publish SARIF; Code scanning uploads must succeed for every configured language.
