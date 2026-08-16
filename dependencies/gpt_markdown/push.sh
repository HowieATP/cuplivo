#!/bin/bash
set -euo pipefail

# Push the gpt_markdown dependency repo without ever putting the token into
# the push URL (token-in-URL shows up in `ps`, shell history, `git remote -v`
# and push error output). The token is injected through GIT_ASKPASS instead.
#
# Usage: push.sh [commit message] [target branch]
# Env:   GITHUB_PERSONAL_ACCESS_TOKEN (required)
#        GPT_MARKDOWN_REMOTE (optional; defaults to the upstream repo URL)

REMOTE="${GPT_MARKDOWN_REMOTE:-https://github.com/Infinitix-LLC/gpt_markdown.git}"
BRANCH="${2:-$(git rev-parse --abbrev-ref HEAD)}"

if [[ -z "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]]; then
  echo "error: GITHUB_PERSONAL_ACCESS_TOKEN is not set" >&2
  exit 1
fi
export GITHUB_PERSONAL_ACCESS_TOKEN

# Refuse to stage obvious secrets or key material.
if git status --porcelain | grep -Eq '(^|/)(\.env|\.pem|\.key|id_rsa|secrets?|.*\.p12)(/|$)'; then
  echo "error: sensitive file detected in the working tree; aborting" >&2
  exit 1
fi

git add -A
if ! git diff --cached --quiet; then
  git commit -m "${1:-Update}"
fi

askpass="$(mktemp)"
chmod +x "$askpass"
trap 'rm -f "$askpass"' EXIT
cat > "$askpass" <<'EOF'
#!/bin/sh
case "$1" in
  *Username*github.com*) echo "x-access-token" ;;
  *Password*github.com*) echo "$GITHUB_PERSONAL_ACCESS_TOKEN" ;;
  *) exit 1 ;;
esac
EOF

GIT_ASKPASS="$askpass" git push "$REMOTE" "$BRANCH"
