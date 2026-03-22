# Security Scan

Scan the entire codebase for security vulnerabilities and report findings.

## Steps

### 1. Scan for Hardcoded Secrets

Search for patterns that indicate hardcoded credentials:

```bash
# API keys, tokens, passwords in source files
grep -rn --include='*.{js,ts,py,rb,go,java,sh,yaml,yml,json,toml,env}' \
  -E '(api[_-]?key|api[_-]?secret|token|password|passwd|secret[_-]?key|access[_-]?key)\s*[:=]\s*["\x27][^"\x27]{8,}' .

# AWS-style keys
grep -rn -E 'AKIA[0-9A-Z]{16}' .

# Private keys
grep -rn -l 'BEGIN (RSA |EC |DSA )?PRIVATE KEY' .

# .env files that shouldn't be committed
find . -name '.env' -not -path './.git/*' -not -path '*/node_modules/*'
```

Flag any findings. Distinguish between:
- **Actual secrets** (real API keys, passwords with real values)
- **Placeholders** (example values like `your-api-key-here`, `changeme`, `xxx`)
- **Test fixtures** (clearly fake values used in test files)

### 2. Check Dependencies for Known Vulnerabilities

Run the appropriate audit command based on what's present in the project:

- **Node.js**: `npm audit` or `yarn audit`
- **Python**: `pip audit` or `safety check`
- **Ruby**: `bundle audit`
- **Go**: `govulncheck ./...`
- **Rust**: `cargo audit`

Record all findings with their severity levels.

### 3. OWASP Top 10 Code Review

Scan for common vulnerability patterns:

- **Injection** (SQL, command, LDAP): Look for string concatenation in queries, unsanitized `exec`/`eval` calls, template injection
- **Broken Authentication**: Weak password handling, missing rate limiting, session mismanagement
- **Sensitive Data Exposure**: Logging secrets, unencrypted storage, verbose error messages in production
- **XML External Entities (XXE)**: Unsafe XML parsing configurations
- **Broken Access Control**: Missing auth checks on routes, IDOR patterns, privilege escalation paths
- **Security Misconfiguration**: Debug mode enabled, default credentials, unnecessary features enabled
- **Cross-Site Scripting (XSS)**: Unsanitized user input rendered in HTML, dangerouslySetInnerHTML usage
- **Insecure Deserialization**: Unsafe `pickle.loads`, `JSON.parse` on untrusted input without validation
- **Using Components with Known Vulnerabilities**: Covered in step 2
- **Insufficient Logging & Monitoring**: Missing audit logs for auth events, no alerting on failures

### 4. Check File Permissions

```bash
# Find world-readable sensitive files
find . -name '*.pem' -o -name '*.key' -o -name '*.env' -o -name '*.secret' | \
  xargs ls -la 2>/dev/null

# Find executable files that shouldn't be
find . -name '*.json' -o -name '*.yaml' -o -name '*.yml' -o -name '*.env' | \
  xargs ls -la 2>/dev/null | grep '^-..x'
```

### 5. Check for Insecure Configurations

- **CORS**: Overly permissive origins (`*` in production)
- **HTTPS**: HTTP-only endpoints, missing HSTS headers
- **CSP**: Missing or weak Content Security Policy
- **Cookies**: Missing Secure/HttpOnly/SameSite flags
- **Rate limiting**: Missing on authentication and sensitive endpoints

### 6. Create Report

Create a GitHub issue titled "Security audit report — [DATE]" with findings organized by severity:

#### Critical
Items requiring immediate attention: hardcoded production secrets, RCE vulnerabilities, auth bypasses.

#### High
Items requiring prompt attention: dependency vulnerabilities with known exploits, SQL injection, XSS.

#### Medium
Items to address in normal development: missing security headers, overly permissive CORS, weak configurations.

#### Low
Items to track: informational findings, best-practice recommendations, minor configuration improvements.

Each finding should include:
- File path and line number
- Description of the vulnerability
- Risk assessment
- Suggested remediation

## Notes

- Never include actual secret values in the report. Redact them (e.g., `AKIA****XXXX`).
- Focus on real risks, not theoretical ones. A hardcoded test API key in a test file is low severity; the same key in production code is critical.
- If the project has a `.security-audit-ignore` file, respect its exclusions but note them in the report.
