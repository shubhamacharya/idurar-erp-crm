#!/usr/bin/env bash
# =============================================================================
# push-secrets-to-github.sh
#
# Reads Terraform outputs and pushes them to GitHub Secrets.
#
# Supports:
#   - Phase 2 (ECR + IAM)
#   - Phase 3 (EC2 + SSH)
#
# Prerequisites:
#   - terraform apply completed
#   - GitHub CLI installed
#   - GitHub CLI authenticated
#   - AWS CLI installed
#
# Usage:
#   chmod +x scripts/push-secrets-to-github.sh
#   ./scripts/push-secrets-to-github.sh
# =============================================================================

set -euo pipefail

# ── Config ───────────────────────────────────────────────────────────────────

TERRAFORM_DIR="$(cd "$(dirname "$0")/../terraform" && pwd)"
GITHUB_REPO="" # auto-detect from git remote

# ── Colors ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
  echo -e "${BLUE}[INFO]${NC}  $1"
}

log_success() {
  echo -e "${GREEN}[OK]${NC}    $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC}  $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
  exit 1
}

echo ""
echo "=============================================="
echo "  GitHub Secrets — automated setup"
echo "=============================================="
echo ""

# ── Step 1: Check prerequisites ──────────────────────────────────────────────

log_info "Checking prerequisites..."

command -v terraform >/dev/null 2>&1 \
  || log_error "terraform not found"

command -v gh >/dev/null 2>&1 \
  || log_error "GitHub CLI not found"

command -v aws >/dev/null 2>&1 \
  || log_error "AWS CLI not found"

gh auth status >/dev/null 2>&1 \
  || log_error "GitHub CLI not authenticated. Run: gh auth login"

log_success "All prerequisites found."

# ── Step 2: Detect GitHub repository ─────────────────────────────────────────

if [[ -z "$GITHUB_REPO" ]]; then
  log_info "Auto-detecting GitHub repository..."

  REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")

  [[ -z "$REMOTE_URL" ]] \
    && log_error "No git remote 'origin' found. Set GITHUB_REPO manually."

  if [[ "$REMOTE_URL" == git@* ]]; then
    GITHUB_REPO=$(echo "$REMOTE_URL" | sed 's/git@github.com://;s/\.git$//')
  else
    GITHUB_REPO=$(echo "$REMOTE_URL" | sed 's|https://github.com/||;s/\.git$//')
  fi

  log_success "Detected repository: ${GITHUB_REPO}"
fi

# ── Step 3: Read Terraform outputs ───────────────────────────────────────────

log_info "Reading Terraform outputs from: ${TERRAFORM_DIR}"

cd "$TERRAFORM_DIR"

[[ -f terraform.tfstate ]] \
  || log_error "terraform.tfstate not found. Run terraform apply first."

AWS_REGION="ap-south-1"

# Required outputs
ECR_REPO_URL=$(terraform output -raw ecr_repo_url)
AWS_ACCESS_KEY_ID=$(terraform output -raw github_actions_access_key_id)
AWS_SECRET_ACCESS_KEY=$(terraform output -raw github_actions_secret_access_key)

# Optional outputs (Phase 3)
EC2_IP=""
SSH_PRIVATE_KEY=""

if terraform output -raw ec2_public_ip >/dev/null 2>&1; then
  EC2_IP=$(terraform output -raw ec2_public_ip)
fi

if terraform output -raw ssh_private_key >/dev/null 2>&1; then
  SSH_PRIVATE_KEY=$(terraform output -raw ssh_private_key)
fi

log_success "Terraform outputs loaded."

# ── Step 4: Preview ──────────────────────────────────────────────────────────

echo ""
echo "The following secrets will be configured:"
echo ""

printf "  %-30s %s\n" "Secret Name" "Value"
printf "  %-30s %s\n" "------------------------------" "--------------------------------------------"

printf "  %-30s %s\n" "AWS_REGION" "$AWS_REGION"
printf "  %-30s %s\n" "ECR_REPO_URL" "$ECR_REPO_URL"
printf "  %-30s %s\n" "AWS_ACCESS_KEY_ID" "$AWS_ACCESS_KEY_ID"
printf "  %-30s %s\n" "AWS_SECRET_ACCESS_KEY" "******"

if [[ -n "$EC2_IP" ]]; then
  printf "  %-30s %s\n" "EC2_HOST" "$EC2_IP"
  printf "  %-30s %s\n" "BACKEND_PUBLIC_URL" "http://${EC2_IP}:8888"
  printf "  %-30s %s\n" "EC2_SSH_KEY" "******"
fi

echo ""

# ── Step 5: Confirm ──────────────────────────────────────────────────────────

read -r -p "Proceed? [y/N] " confirm

[[ "${confirm,,}" == "y" ]] || {
  echo "Aborted."
  exit 0
}

echo ""

# ── Step 6: Push secrets ─────────────────────────────────────────────────────

log_info "Pushing secrets to GitHub..."

push_secret() {
  local name="$1"
  local value="$2"

  printf "  Setting %-30s ... " "$name"

  echo "$value" | gh secret set "$name" \
    --repo "$GITHUB_REPO"

  echo -e "${GREEN}done${NC}"
}

push_secret "AWS_REGION" "$AWS_REGION"
push_secret "ECR_REPO_URL" "$ECR_REPO_URL"
push_secret "AWS_ACCESS_KEY_ID" "$AWS_ACCESS_KEY_ID"
push_secret "AWS_SECRET_ACCESS_KEY" "$AWS_SECRET_ACCESS_KEY"

if [[ -n "$EC2_IP" ]]; then
  push_secret "EC2_HOST" "$EC2_IP"
  push_secret "BACKEND_PUBLIC_URL" "http://${EC2_IP}:8888"

  if [[ -n "$SSH_PRIVATE_KEY" ]]; then
    printf "  Setting %-30s ... " "EC2_SSH_KEY"

    echo "$SSH_PRIVATE_KEY" | gh secret set EC2_SSH_KEY \
      --repo "$GITHUB_REPO"

    echo -e "${GREEN}done${NC}"
  fi

  log_success "Phase 3 secrets configured."
else
  log_warn "EC2 outputs not found. Skipping EC2 secrets."
fi

# ── Step 7: Remove old secrets ───────────────────────────────────────────────

echo ""
log_info "Removing legacy ECR secrets if present..."

gh secret delete ECR_BACKEND_URL \
  --repo "$GITHUB_REPO" 2>/dev/null \
  && echo "  Deleted ECR_BACKEND_URL" \
  || echo "  ECR_BACKEND_URL not found"

gh secret delete ECR_FRONTEND_URL \
  --repo "$GITHUB_REPO" 2>/dev/null \
  && echo "  Deleted ECR_FRONTEND_URL" \
  || echo "  ECR_FRONTEND_URL not found"

# ── Step 8: Verify ───────────────────────────────────────────────────────────

echo ""
log_info "Current GitHub secrets:"
echo ""

gh secret list --repo "$GITHUB_REPO"

echo ""

if [[ -n "$EC2_IP" ]]; then
  log_success "All GitHub secrets configured successfully."
else
  log_success "Phase 2 secrets configured."

  echo ""
  log_warn "Run this script again after EC2 deployment to configure:"
  echo ""
  echo "  EC2_HOST"
  echo "  BACKEND_PUBLIC_URL"
  echo "  EC2_SSH_KEY"
fi

echo ""
echo "GitHub Actions:"
echo "https://github.com/${GITHUB_REPO}/actions"
echo ""