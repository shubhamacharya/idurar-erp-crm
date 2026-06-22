#!/usr/bin/env bash
# =============================================================================
# push-secrets-to-github.sh
#
# Reads Terraform outputs directly and pushes them to GitHub Secrets.
# No manual copy-pasting of keys or URLs.
#
# Prerequisites:
#   - terraform apply already completed in terraform/
#   - GitHub CLI installed  (brew install gh  OR  https://cli.github.com)
#   - GitHub CLI authenticated  (gh auth login)
#
# Usage:
#   chmod +x scripts/push-secrets-to-github.sh
#   ./scripts/push-secrets-to-github.sh
# =============================================================================

set -euo pipefail

# ── Config ───────────────────────────────────────────────────────────────────
# Points to the ROOT terraform dir (not ecr/ submodule — outputs are at root)
TERRAFORM_DIR="$(cd "$(dirname "$0")/../terraform" && pwd)"
GITHUB_REPO=""   # auto-detected from git remote, or set manually e.g. "shubham/idurar-erp-crm"

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

echo ""
echo "=============================================="
echo "  GitHub Secrets — automated setup"
echo "=============================================="
echo ""

# ── Step 1: Check prerequisites ───────────────────────────────────────────────
log_info "Checking prerequisites..."

command -v terraform &>/dev/null || log_error "terraform not found. Install from https://developer.hashicorp.com/terraform/install"
command -v gh        &>/dev/null || log_error "GitHub CLI not found. Install from https://cli.github.com"
command -v aws       &>/dev/null || log_error "AWS CLI not found."

gh auth status &>/dev/null || log_error "GitHub CLI not authenticated. Run: gh auth login"

log_success "All prerequisites found."

# ── Step 2: Auto-detect GitHub repo from git remote ───────────────────────────
if [[ -z "$GITHUB_REPO" ]]; then
  log_info "Auto-detecting GitHub repo from git remote..."
  REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")

  [[ -z "$REMOTE_URL" ]] && log_error "No git remote 'origin' found. Set GITHUB_REPO manually in this script."

  if [[ "$REMOTE_URL" == git@* ]]; then
    GITHUB_REPO=$(echo "$REMOTE_URL" | sed 's/git@github.com://;s/\.git$//')
  else
    GITHUB_REPO=$(echo "$REMOTE_URL" | sed 's|https://github.com/||;s/\.git$//')
  fi

  log_success "Detected repo: ${GITHUB_REPO}"
fi

# ── Step 3: Read Terraform outputs ────────────────────────────────────────────
log_info "Reading Terraform outputs from: ${TERRAFORM_DIR}"

cd "$TERRAFORM_DIR"

[[ -f terraform.tfstate ]] || log_error "No terraform.tfstate found in ${TERRAFORM_DIR}. Run 'terraform apply' first."

# Root module outputs — sourced from child modules
# AWS_REGION=$(terraform output -raw aws_region)
AWS_REGION="ap-south-1"

# ECR — single repo URL (module.registry.repository_url)
ECR_REPO_URL=$(terraform output -raw ecr_repo_url)

# IAM user credentials for GitHub Actions (module.iam outputs)
AWS_ACCESS_KEY_ID=$(terraform output -raw github_actions_access_key_id)
AWS_SECRET_ACCESS_KEY=$(terraform output -raw github_actions_secret_access_key)

log_success "Terraform outputs read successfully."

# ── Step 4: Preview ───────────────────────────────────────────────────────────
echo ""
echo "The following secrets will be set on: ${GITHUB_REPO}"
echo ""
printf "  %-30s %s\n" "Secret name" "Value"
printf "  %-30s %s\n" "───────────────────────────" "──────────────────────────────────────────────────────────"
printf "  %-30s %s\n" "AWS_REGION"            "$AWS_REGION"
printf "  %-30s %s\n" "ECR_REPO_URL"          "$ECR_REPO_URL"
printf "  %-30s %s\n" "AWS_ACCESS_KEY_ID"     "$AWS_ACCESS_KEY_ID"
printf "  %-30s %s\n" "AWS_SECRET_ACCESS_KEY" "****** (sensitive, not shown)"
echo ""
log_warn "BACKEND_PUBLIC_URL and EC2_HOST + EC2_SSH_KEY will be set in Phase 3 after terraform apply for EC2."
echo ""

# ── Step 5: Confirm ───────────────────────────────────────────────────────────
read -r -p "Proceed? [y/N] " confirm
[[ "${confirm,,}" == "y" ]] || { echo "Aborted."; exit 0; }
echo ""

# ── Step 6: Push secrets ──────────────────────────────────────────────────────
log_info "Pushing secrets to GitHub..."

push_secret() {
  local name="$1"
  local value="$2"
  printf "  Setting %-30s ... " "$name"
  echo "$value" | gh secret set "$name" --repo "$GITHUB_REPO"
  echo -e "${GREEN}done${NC}"
}

push_secret "AWS_REGION"            "$AWS_REGION"
push_secret "ECR_REPO_URL"          "$ECR_REPO_URL"
push_secret "AWS_ACCESS_KEY_ID"     "$AWS_ACCESS_KEY_ID"
push_secret "AWS_SECRET_ACCESS_KEY" "$AWS_SECRET_ACCESS_KEY"

# ── Step 7: Clean up old secrets if they exist ────────────────────────────────
# The old architecture used two separate ECR secrets — remove them
# so the workflow doesn't accidentally pick up stale values.
echo ""
log_info "Removing old ECR_BACKEND_URL and ECR_FRONTEND_URL secrets if present..."

gh secret delete ECR_BACKEND_URL  --repo "$GITHUB_REPO" 2>/dev/null \
  && echo -e "  Deleted ECR_BACKEND_URL" \
  || echo -e "  ECR_BACKEND_URL not found — skipping"

gh secret delete ECR_FRONTEND_URL --repo "$GITHUB_REPO" 2>/dev/null \
  && echo -e "  Deleted ECR_FRONTEND_URL" \
  || echo -e "  ECR_FRONTEND_URL not found — skipping"

# ── Step 8: Verify ───────────────────────────────────────────────────────────
echo ""
log_info "Current secrets on GitHub:"
echo ""
gh secret list --repo "$GITHUB_REPO"

echo ""
log_success "Phase 2 secrets set. Remaining secrets for Phase 3:"
echo ""
echo "  BACKEND_PUBLIC_URL  — http://<EC2_IP>:8888  (set after terraform apply for EC2)"
echo "  EC2_HOST            — <EC2_IP>              (set after terraform apply for EC2)"
echo "  EC2_SSH_KEY         — contents of ~/.ssh/idurar-key (set after key pair creation)"
echo ""
echo "Next step: commit and push your workflow file, then check:"
echo "  https://github.com/${GITHUB_REPO}/actions"
echo ""