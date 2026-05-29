
**See also**: [REPORULES.md](../REPORULES.md) — multi-machine sync, git identity, PAT handling, and new-repo bootstrap.

# AGENTS.md — KirkForge

## ⚠️ Mandatory Rules — Read Before Editing

- **Never commit**: `node_modules/`, `.venv/`, `venv/`, `__pycache__/`, `*.pyc`, `dist/`, `build/`, `.next/`, `coverage/`, `.mypy_cache/`, `.pytest_cache/`, `.ruff_cache/`, `.tox/`, `.DS_Store`, `*.log`, `.env`, `*.pem`, `*.key`
- **Always pull before work, push after work**
- **Git identity**: `Henrik Kirk <285947470+KirkForge@users.noreply.github.com>`
- **Commit format**: `type(scope): message` — feat, fix, docs, refactor, test, chore, wip
- **Pre-push CI**: `ci-cleandev` hooks block pushes on failure. Fix, don't bypass.

## Project Rules

- Keep files minimal and clean
- Don't add generated or dependency files

## Before Editing

1. `git pull`
2. Check `.gitignore` — don't stage ignored files
3. Check this file for project-specific rules

## Before Committing

1. `git status --short` — review staged files
2. No secrets, no generated files, no cache directories
3. `git diff --cached` — verify actual content
4. Let pre-push CI pass before pushing

---

## 🔒 Secure-Defaults Checklist (Definition of Done)

> **The rule:** The secure state is the DEFAULT. Opening it up is an EXPLICIT, LOGGED, opt-in — never the fallback.

### Network binding
- [ ] Servers bind `127.0.0.1` by default. Non-loopback requires explicit flag/env AND auth enabled.
- [ ] Non-loopback bind logs a startup WARNING naming the exposure.
- [ ] CORS / allowed-hosts default to an explicit allowlist, never `["*"]`.

### Secrets
- [ ] No secret has a usable default value. Missing secret in production → refuse to boot (`exit 1`).
- [ ] Empty-string / placeholder secrets are never a valid signing key, even in dev. Generate random per-process secret if none supplied (+ warning).
- [ ] No secret value is written into generated artifacts (systemd units, configmaps, scripts).
- [ ] Secrets come from env or a secret manager — never a committed file. `*token*.json`, `credentials*.json` etc. are gitignored.

### Comparisons (constant-time)
- [ ] Every secret / token / signature / hash comparison uses constant-time compare (`hmac.compare_digest` / `crypto.timingSafeEqual`), never `==` / `!==`.
- [ ] `grep -rEn '(sig|hmac|token|secret|hash|key)\b.*(==|!=|!==)' src/` returns nothing that compares a secret.

### Allowlists / deny-by-default
- [ ] An empty allowlist means DENY, never ALLOW-ALL.
- [ ] Filesystem paths from tool/API input are confined to a configured root by default; arbitrary paths require explicit opt-in.
- [ ] Command execution uses argv arrays, never `shell=True` / string interpolation. Raw-shell paths gated behind `ALLOW_UNSAFE_*=1`, default off.

### Multi-tenant isolation
- [ ] Every shared store (sessions, cache, files, memory, routing) is keyed by `tenant_id`, not a global namespace.
- [ ] List/enumerate endpoints scope results to the calling tenant.
- [ ] Identity (owner/role/tenant) is derived from the authenticated session/token, never from the request body.
- [ ] At least one test asserts tenant A cannot read/modify tenant B's data.

### Authorization (not just authentication)
- [ ] Every protected endpoint calls BOTH authn (who are you) AND authz (are you allowed).
- [ ] New endpoints are deny-by-default — added to the authz table, not left to fall through.

### Sandbox / untrusted execution
- [ ] Child processes get an explicit env allowlist, not `{...process.env}` inheritance.
- [ ] For untrusted/model-generated code, real isolation (container/microVM/namespaces + rlimits + no-new-privs) is the DEFAULT path; bare-host "constrained" is opt-in with a warning.
- [ ] Isolation claims in README match what the code enforces. No "kernel-enforced"/"enterprise-grade" unless it is.

### Claims vs reality
- [ ] README maturity label matches code reality.
- [ ] Threat model is documented for anything that takes untrusted input.
- [ ] No dead code that implies a capability the product doesn't have.
