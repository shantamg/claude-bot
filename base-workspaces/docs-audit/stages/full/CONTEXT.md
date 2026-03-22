# Full Docs Audit

Comprehensive, manual audit of all project documentation against the current codebase.

## Steps

### 1. Inventory All Documentation

Find every documentation file in the project:

```bash
find . -name '*.md' -not -path './.git/*' -not -path './node_modules/*' -not -path './_active/*'
```

Also check for:
- Docs directories (`docs/`, `documentation/`, `wiki/`)
- Inline JSDoc / docstrings in source files (spot-check, not exhaustive)
- Config file comments that serve as documentation

### 2. Cross-Reference with Code

For each documentation file, verify:

- **File paths and directory references** — Do referenced paths actually exist?
- **Code examples** — Do code snippets compile/run? Do they match current APIs?
- **API documentation** — Do documented endpoints, parameters, and responses match the code?
- **Configuration references** — Do documented env vars, config keys, and defaults match reality?
- **Architecture descriptions** — Do described module relationships, data flows, and dependencies reflect the current codebase?
- **Setup/install instructions** — Do the steps actually work with the current project state?

### 3. Check for Broken Links

For each Markdown file, verify:
- Internal links (relative paths to other docs or code) resolve correctly
- External links return 2xx status codes (skip known-flaky domains)
- Anchor links (`#section-name`) point to existing headings

### 4. Identify Missing Documentation

Look for undocumented areas:
- Public API endpoints with no corresponding docs
- Config files with no schema documentation
- Complex modules with no architectural explanation
- Recent features (last 30 days of commits) with no documentation

### 5. Create Structured Report

Create a GitHub issue titled "Full docs audit report" with sections:

#### Critical (blocking users)
- Broken instructions that would cause setup/usage failures
- Completely wrong API documentation

#### High (misleading)
- Outdated code examples
- Wrong config references
- Stale architecture diagrams

#### Medium (incomplete)
- Missing docs for public APIs
- Undocumented config options
- Missing setup steps

#### Low (cosmetic)
- Broken external links
- Minor inaccuracies
- Missing but non-essential docs

## Notes

- This is a thorough audit — take your time and be comprehensive.
- Prioritize accuracy over speed. Read the actual code before judging documentation.
- When a doc is outdated, include a concrete suggestion for what it should say instead.
