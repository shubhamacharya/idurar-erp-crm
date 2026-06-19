#!/usr/bin/env bash
# =============================================================================
# push-secrets-to-github.sh
#
# Reads Terraform outputs directly and pushes them to GitHub Secrets.
# No manual copy-pasting of keys or URLs.
#
# Prerequisites:
#   - terraform apply already completed in terraform/ecr/
#   - GitHub CLI installed  (brew install gh  OR  https://cli.github.com)
#   - GitHub CLI authenticated  (gh auth login)
#
# Usage:
#   chmod +x scripts/push-secrets-to-github.sh
#   ./scripts/push-secrets-to-github.sh
# =============================================================================

set -euo pipefail   # exit on error, undefined var, or pipe failure

# ── Config ───────────────────────────────────────────────────────────────────
TERRAFORM_DIR="$(cd "$(dirname "$0")/../terraform/" && pwd)"
GITHUB_REPO=""   # auto-detected from git remote, or set manually e.g. "shubham/idurar-erp-crm"

# ── Colors for output ────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'  # no color

log_info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ── Step 1: Check prerequisites ───────────────────────────────────────────────
echo ""
echo "=============================================="
echo "  GitHub Secrets — automated setup"
echo "=============================================="
echo ""

log_info "Checking prerequisites..."

command -v terraform &>/dev/null || log_error "terraform not found. Install from https://developer.hashicorp.com/terraform/install"
command -v gh        &>/dev/null || log_error "GitHub CLI not found. Install from https://cli.github.com"
command -v aws       &>/dev/null || log_error "AWS CLI not found. Install from https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"

# Check GitHub CLI is authenticated
gh auth status &>/dev/null || log_error "GitHub CLI not authenticated. Run: gh auth login"

log_success "All prerequisites found."

# ── Step 2: Auto-detect GitHub repo from git remote ───────────────────────────
if [[ -z "$GITHUB_REPO" ]]; then
  log_info "Auto-detecting GitHub repo from git remote..."
  REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")

  if [[ -z "$REMOTE_URL" ]]; then
    log_error "No git remote 'origin' found. Set GITHUB_REPO manually in this script."
  fi

  # Handle both SSH and HTTPS remote formats:
  # SSH:   git@github.com:shubham/idurar-erp-crm.git
  # HTTPS: https://github.com/shubham/idurar-erp-crm.git
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

# Verify terraform state exists
[[ -f terraform.tfstate ]] || log_error "No terraform.tfstate found. Run 'terraform apply' first."

AWS_REGION=$(terraform output -raw aws_region)
ECR_BACKEND_URL=$(terraform output -raw backend_repository_url)
ECR_FRONTEND_URL=$(terraform output -raw frontend_repository_url)
AWS_ACCESS_KEY_ID=$(terraform output -raw github_actions_access_key_id)
AWS_SECRET_ACCESS_KEY=$(terraform output -raw github_actions_secret_access_key)

log_success "Terraform outputs read successfully."

# ── Step 4: Preview what will be set ─────────────────────────────────────────
echo ""
echo "The following secrets will be set on: ${GITHUB_REPO}"
echo ""
printf "  %-30s %s\n" "Secret name" "Value"
printf "  %-30s %s\n" "───────────────────────────" "────────────────────────────────────────────────────────────"
printf "  %-30s %s\n" "AWS_REGION"               "$AWS_REGION"
printf "  %-30s %s\n" "ECR_BACKEND_URL"           "$ECR_BACKEND_URL"
printf "  %-30s %s\n" "ECR_FRONTEND_URL"          "$ECR_FRONTEND_URL"
printf "  %-30s %s\n" "AWS_ACCESS_KEY_ID"         "$AWS_ACCESS_KEY_ID"
printf "  %-30s %s\n" "AWS_SECRET_ACCESS_KEY"     "****** (sensitive, not shown)"
echo ""

# ── Step 5: Confirm before pushing ───────────────────────────────────────────
read -r -p "Proceed? [y/N] " confirm
[[ "${confirm,,}" == "y" ]] || { echo "Aborted."; exit 0; }
echo ""

# ── Step 6: Push secrets to GitHub ───────────────────────────────────────────
log_info "Pushing secrets to GitHub..."

push_secret() {
  local name="$1"
  local value="$2"
  printf "  Setting %-30s ... " "$name"
  echo "$value" | gh secret set "$name" --repo "$GITHUB_REPO"
  echo -e "${GREEN}done${NC}"
}

push_secret "AWS_REGION"               "$AWS_REGION"
push_secret "ECR_BACKEND_URL"          "$ECR_BACKEND_URL"
push_secret "ECR_FRONTEND_URL"         "$ECR_FRONTEND_URL"
push_secret "AWS_ACCESS_KEY_ID"        "$AWS_ACCESS_KEY_ID"
push_secret "AWS_SECRET_ACCESS_KEY"    "$AWS_SECRET_ACCESS_KEY"

# ── Step 7: Verify ───────────────────────────────────────────────────────────
echo ""
log_info "Verifying secrets on GitHub..."
echo ""
gh secret list --repo "$GITHUB_REPO"

echo ""
log_success "All secrets set. GitHub Actions pipeline is ready."
echo ""
echo "Next step: commit and push your workflow file, then check:"
echo "  https://github.com/${GITHUB_REPO}/actions"
echo ""