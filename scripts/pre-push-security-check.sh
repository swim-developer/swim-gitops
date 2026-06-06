#!/usr/bin/env bash
# Scan swim-gitops for files that must not be committed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FAIL=0

echo "== swim-gitops pre-push security check =="
echo "Root: $ROOT"
echo

# Binary / cert material
PATTERNS=(
  '*.pem'
  '*.key'
  '*.p12'
  '*.jks'
  '*.pfx'
  'id_rsa'
  'id_ed25519'
  '*.kubeconfig'
)

for pat in "${PATTERNS[@]}"; do
  if find . -path './.git' -prune -o -name "$pat" -print 2>/dev/null | grep -q .; then
    echo "FAIL: found forbidden pattern: $pat"
    find . -path './.git' -prune -o -name "$pat" -print
    FAIL=1
  fi
done

# Red Hat pull secret (CRC only; must stay local)
for f in pull-secret pull-secret.txt pull-secret.json; do
  if git ls-files --error-unmatch "$f" 2>/dev/null; then
    echo "FAIL: $f must not be committed (use local file + .gitignore)"
    FAIL=1
  fi
done
if git ls-files 2>/dev/null | grep -qE '(^|/)pull-secret\.'; then
  echo "FAIL: pull-secret.* must not be committed"
  git ls-files | grep -E '(^|/)pull-secret\.' || true
  FAIL=1
fi

# JAR binaries (Keycloak SPI must not be in git)
if find . -path './.git' -prune -o -name '*.jar' -print 2>/dev/null | grep -q .; then
  echo "FAIL: .jar files must not be committed (use cluster secret for SPI)"
  find . -path './.git' -prune -o -name '*.jar' -print
  FAIL=1
fi

# Obvious secret literals (tokens), excluding template placeholders
if rg -n --hidden --glob '!.git' \
  -e 'docker-password:\s*[A-Za-z0-9._-]{20,}' \
  -e 'ghp_[A-Za-z0-9]{20,}' \
  -e 'github_pat_[A-Za-z0-9_]{20,}' \
  -e 'quay\.io/[A-Za-z0-9]+:[A-Za-z0-9]{40,}' \
  . 2>/dev/null; then
  echo "FAIL: possible API token in repo"
  FAIL=1
fi

# BEGIN private key blocks
if rg -n --hidden --glob '!.git' 'BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY' . 2>/dev/null; then
  echo "FAIL: private key material in repo"
  FAIL=1
fi

# Remind about demo passwords (informational, not fail)
DEMO_PW=$(rg -l 'password:\s*(swim|admin|password|swim123)' infra apps 2>/dev/null | wc -l | tr -d ' ')
if [[ "$DEMO_PW" -gt 0 ]]; then
  echo "INFO: $DEMO_PW file(s) contain demo passwords (OK for CRC; see SECURITY.md)"
fi

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "PASS: no blocked secret artifacts detected."
  exit 0
fi

echo "FAILED: fix issues before pushing to public GitHub."
exit 1
