#!/usr/bin/env bash
# =============================================================================
# push-secrets-to-github.sh
#
# Reads ALL Terraform outputs and pushes them to GitHub Secrets.
# Safe to run after Phase 2 (ECR+IAM) AND after Phase 3 (EC2).
#
# Run after Phase 2:  sets AWS_REGION, ECR_REPO_URL, AWS_ACCESS_KEY_ID,
#                         AWS_SECRET_ACCESS_KEY
# Run after Phase 3:  additionally sets EC2_HOST, EC2_SSH_KEY,
#                         BACKEND_PUBLIC_URL
#
# Prerequisites:
#   - terraform apply already completed (at least module.registry + module.iam)
#   - GitHub CLI installed and authenticated (gh auth login)
#
# Usage:
#   chmod +x scripts/push-secrets-to-github.sh
#   ./scripts/push-secrets-to-github.sh
# =============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
TERRAFORM_DIR="$(cd "$(dirname "$0")/../terraform" && pwd)"
GITHUB_REPO=""   # auto-detected from git remote

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
log_skip()    { echo -e "  ${YELLOW}[SKIP]${NC}  $1 — not available yet"; }

echo ""
echo "=============================================="
echo "  GitHub Secrets — automated setup"
echo "=============================================="
echo ""

# ── Step 1: Prerequisites ─────────────────────────────────────────────────────
log_info "Checking prerequisites..."
command -v terraform &>/dev/null || log_error "terraform not found."
command -v gh        &>/dev/null || log_error "GitHub CLI not found. Run: brew install gh"
command -v aws       &>/dev/null || log_error "AWS CLI not found."
gh auth status &>/dev/null       || log_error "GitHub CLI not authenticated. Run: gh auth login"
log_success "All prerequisites found."

# ── Step 2: Auto-detect GitHub repo ───────────────────────────────────────────
if [[ -z "$GITHUB_REPO" ]]; then
  log_info "Auto-detecting GitHub repo from git remote..."
  REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")
  [[ -z "$REMOTE_URL" ]] && log_error "No git remote 'origin' found."

  if [[ "$REMOTE_URL" == git@* ]]; then
    GITHUB_REPO=$(echo "$REMOTE_URL" | sed 's/git@github.com://;s/\.git$//')
  else
    GITHUB_REPO=$(echo "$REMOTE_URL" | sed 's|https://github.com/||;s/\.git$//')
  fi
  log_success "Detected repo: ${GITHUB_REPO}"
fi

# ── Step 3: Verify Terraform state exists ─────────────────────────────────────
cd "$TERRAFORM_DIR"
[[ -f terraform.tfstate ]] \
  || log_error "No terraform.tfstate found. Run 'terraform apply -target=module.registry -target=module.iam' first."

# ── Step 4: Helper — try to read a terraform output, return empty if missing ──
# This is the key function that makes the script safe to run at any phase.
# If module.ec2 hasn't been applied yet, EC2 outputs won't exist —
# the script skips them gracefully instead of failing.
tf_output() {
  local name="$1"
  terraform output -raw "$name" 2>/dev/null || echo ""
}

# ── Step 5: Read all outputs ──────────────────────────────────────────────────
log_info "Reading Terraform outputs..."

# Phase 2 — always available after module.registry + module.iam
AWS_REGION="ap-south-1"   # read directly from var — never depends on module state
ECR_REPO_URL=$(tf_output "ecr_repo_url")
AWS_ACCESS_KEY_ID=$(tf_output "github_actions_access_key_id")
AWS_SECRET_ACCESS_KEY=$(tf_output "github_actions_secret_access_key")

# Phase 3 — only available after module.ec2
EC2_PUBLIC_IP=$(tf_output "ec2_public_ip")
EC2_SSH_KEY=$(tf_output "ssh_private_key")

# Derive BACKEND_PUBLIC_URL from EC2 IP if available
if [[ -n "$EC2_PUBLIC_IP" ]]; then
  BACKEND_PUBLIC_URL="http://${EC2_PUBLIC_IP}:8888"
else
  BACKEND_PUBLIC_URL=""
fi

log_success "Outputs read."

# ── Step 6: Preview ───────────────────────────────────────────────────────────
echo ""
echo "Secrets to be set on: ${GITHUB_REPO}"
echo ""
printf "  %-30s %-50s %s\n" "Secret" "Value" "Status"
printf "  %-30s %-50s %s\n" "──────────────────────────────" "──────────────────────────────────────────────────" "────────"

print_row() {
  local name="$1" value="$2" display="$3"
  if [[ -n "$value" ]]; then
    printf "  %-30s %-50s %s\n" "$name" "$display" "${GREEN}ready${NC}"
  else
    printf "  %-30s %-50s %s\n" "$name" "(not available yet)" "${YELLOW}skip${NC}"
  fi
}

print_row "AWS_REGION"            "$AWS_REGION"            "$AWS_REGION"
print_row "ECR_REPO_URL"          "$ECR_REPO_URL"          "$ECR_REPO_URL"
print_row "AWS_ACCESS_KEY_ID"     "$AWS_ACCESS_KEY_ID"     "$AWS_ACCESS_KEY_ID"
print_row "AWS_SECRET_ACCESS_KEY" "$AWS_SECRET_ACCESS_KEY" "****** (sensitive)"
print_row "EC2_HOST"              "$EC2_PUBLIC_IP"         "$EC2_PUBLIC_IP"
print_row "BACKEND_PUBLIC_URL"    "$BACKEND_PUBLIC_URL"    "$BACKEND_PUBLIC_URL"
print_row "EC2_SSH_KEY"           "$EC2_SSH_KEY"           "****** (sensitive)"
echo ""

# Warn if EC2 secrets are not yet available
if [[ -z "$EC2_PUBLIC_IP" ]]; then
  log_warn "EC2 secrets (EC2_HOST, EC2_SSH_KEY, BACKEND_PUBLIC_URL) not available."
  log_warn "Run 'terraform apply -target=module.ec2' then re-run this script."
fi

# ── Step 7: Confirm ───────────────────────────────────────────────────────────
read -r -p "Proceed? [y/N] " confirm
[[ "${confirm,,}" == "y" ]] || { echo "Aborted."; exit 0; }
echo ""

# ── Step 8: Push secrets ──────────────────────────────────────────────────────
log_info "Pushing secrets to GitHub..."

push_secret() {
  local name="$1"
  local value="$2"
  if [[ -n "$value" ]]; then
    printf "  Setting %-30s ... " "$name"
    echo "$value" | gh secret set "$name" --repo "$GITHUB_REPO"
    printf '%s' "$value" | gh secret set "$name" \
    --repo "$GITHUB_REPO" \
    --env production
    echo -e "${GREEN}done${NC}"
  else
    log_skip "$name"
  fi
}

# Phase 2 secrets
push_secret "AWS_REGION"            "$AWS_REGION"
push_secret "ECR_REPO_URL"          "$ECR_REPO_URL"
push_secret "AWS_ACCESS_KEY_ID"     "$AWS_ACCESS_KEY_ID"
push_secret "AWS_SECRET_ACCESS_KEY" "$AWS_SECRET_ACCESS_KEY"

# Phase 3 secrets — pushed only if EC2 has been applied
push_secret "EC2_HOST"           "$EC2_PUBLIC_IP"
push_secret "BACKEND_PUBLIC_URL" "$BACKEND_PUBLIC_URL"
push_secret "EC2_SSH_KEY"        "$EC2_SSH_KEY"

# ── Step 9: Clean up stale secrets from old architecture ──────────────────────
echo ""
log_info "Removing stale secrets from old two-repo architecture..."
for old in ECR_BACKEND_URL ECR_FRONTEND_URL; do
  gh secret delete "$old" --repo "$GITHUB_REPO" 2>/dev/null \
    && echo -e "  Deleted ${old}" \
    || echo -e "  ${old} not present — skipping"
done

# ── Step 10: Verify ───────────────────────────────────────────────────────────
echo ""
log_info "Current secrets on GitHub:"
echo ""
gh secret list --repo "$GITHUB_REPO"

echo ""
log_success "Done."

# Final status — tell user what's still pending
if [[ -z "$EC2_PUBLIC_IP" ]]; then
  echo ""
  echo "  Phase 3 secrets still pending. After EC2 is provisioned, run:"
  echo ""
  echo "    terraform -chdir=${TERRAFORM_DIR} apply -target=module.ec2"
  echo "    ./scripts/push-secrets-to-github.sh"
  echo ""
else
  echo ""
  echo "  All secrets set. Trigger the pipeline:"
  echo ""
  echo "    git commit --allow-empty -m 'ci: trigger full deploy'"
  echo "    git push origin main"
  echo ""
fi