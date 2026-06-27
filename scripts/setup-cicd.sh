#!/usr/bin/env bash
# =============================================================================
# setup-cicd.sh
#
# Places the CI/CD workflow file into the correct location in your idurar repo,
# then commits and pushes to trigger the first pipeline run.
#
# Run this from the ROOT of your cloned idurar-erp-crm repo:
#   chmod +x setup-cicd.sh
#   ./setup-cicd.sh
# =============================================================================

set -euo pipefail

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ── Verify we are in the repo root ───────────────────────────────────────────
[[ -d "backend" && -d "frontend" ]] \
  || log_error "Run this script from the root of your idurar-erp-crm repo."

echo ""
echo "=============================================="
echo "  idurar CI/CD — file setup"
echo "=============================================="
echo ""

# ── 1. GitHub Actions workflow ────────────────────────────────────────────────
log_info "Creating .github/workflows/ci-cd.yml ..."
mkdir -p .github/workflows

cat > .github/workflows/ci-cd.yml << 'EOF'
name: CI/CD Pipeline

on:
  push:
    branches: [main, master]
  pull_request:
    branches: [main, master]

env:
  AWS_REGION:   ${{ secrets.AWS_REGION }}
  ECR_REPO_URL: ${{ secrets.ECR_REPO_URL }}

jobs:

  # ── Job 1: Lint & Test ─────────────────────────────────────────────────────
  lint-and-test:
    name: Lint & Test
    runs-on: ubuntu-latest

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Set up Node.js (backend)
        uses: actions/setup-node@v4
        with:
          node-version: "24"
          cache: "npm"
          cache-dependency-path: backend/package-lock.json

      - name: Install backend dependencies
        working-directory: backend
        run: npm ci

      - name: Lint backend
        working-directory: backend
        run: npm run lint --if-present

      - name: Test backend
        working-directory: backend
        run: npm test --if-present
        env:
          NODE_ENV: test

      - name: Set up Node.js (frontend)
        uses: actions/setup-node@v4
        with:
          node-version: "24"
          cache: "npm"
          cache-dependency-path: frontend/package-lock.json

      - name: Install frontend dependencies
        working-directory: frontend
        run: npm ci

      - name: Lint frontend
        working-directory: frontend
        run: npm run lint --if-present

      - name: Build frontend (compile check)
        working-directory: frontend
        run: npm run build
        env:
          VITE_BACKEND_URL: http://0.0.0.0:8888

  # ── Job 2: Build & Push to ECR ────────────────────────────────────────────
  build-and-push:
    name: Build & Push to ECR
    runs-on: ubuntu-latest
    needs: lint-and-test
    if: github.event_name == 'push'

    outputs:
      image-tag: ${{ steps.meta.outputs.tag }}

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Generate image tag
        id: meta
        run: |
          SHORT_SHA=$(echo ${{ github.sha }} | cut -c1-7)
          echo "tag=${SHORT_SHA}" >> $GITHUB_OUTPUT
          echo "Image tag: ${SHORT_SHA}"

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id:     ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region:            ${{ secrets.AWS_REGION }}

      - name: Login to Amazon ECR
        uses: aws-actions/amazon-ecr-login@v2

      # Single ECR repo — backend and frontend differentiated by tag prefix
      - name: Build backend image
        working-directory: backend
        run: |
          docker build \
            --tag ${{ env.ECR_REPO_URL }}:backend-${{ steps.meta.outputs.tag }} \
            --tag ${{ env.ECR_REPO_URL }}:backend-latest \
            --file Dockerfile \
            .

      - name: Push backend image
        run: |
          docker push ${{ env.ECR_REPO_URL }}:backend-${{ steps.meta.outputs.tag }}
          docker push ${{ env.ECR_REPO_URL }}:backend-latest

      - name: Build frontend image
        working-directory: frontend
        run: |
          docker build \
            --tag ${{ env.ECR_REPO_URL }}:frontend-${{ steps.meta.outputs.tag }} \
            --tag ${{ env.ECR_REPO_URL }}:frontend-latest \
            --file Dockerfile \
            --build-arg VITE_BACKEND_URL=${{ secrets.BACKEND_PUBLIC_URL }} \
            .

      - name: Push frontend image
        run: |
          docker push ${{ env.ECR_REPO_URL }}:frontend-${{ steps.meta.outputs.tag }}
          docker push ${{ env.ECR_REPO_URL }}:frontend-latest

      - name: Print image summary
        run: |
          echo "### Images pushed to ECR" >> $GITHUB_STEP_SUMMARY
          echo "| Image | Tag |" >> $GITHUB_STEP_SUMMARY
          echo "|---|---|" >> $GITHUB_STEP_SUMMARY
          echo "| Backend  | \`backend-${{ steps.meta.outputs.tag }}\` |" >> $GITHUB_STEP_SUMMARY
          echo "| Frontend | \`frontend-${{ steps.meta.outputs.tag }}\` |" >> $GITHUB_STEP_SUMMARY

  # ── Job 3: Deploy to EC2 ───────────────────────────────────────────────────
  deploy:
    name: Deploy to EC2
    runs-on: ubuntu-latest
    needs: build-and-push
    if: github.event_name == 'push'

    steps:
      - name: SSH into EC2 and redeploy
        uses: appleboy/ssh-action@v1
        with:
          host:     ${{ secrets.EC2_HOST }}
          username: ubuntu
          key:      ${{ secrets.EC2_SSH_KEY }}
          script: |
            /home/ubuntu/redeploy.sh

      - name: Verify deployment
        uses: appleboy/ssh-action@v1
        with:
          host:     ${{ secrets.EC2_HOST }}
          username: ubuntu
          key:      ${{ secrets.EC2_SSH_KEY }}
          script: |
            echo "=== Running containers ==="
            docker ps --filter "name=idurar" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

            echo ""
            echo "=== Backend health check (via Nginx) ==="
            curl -sf http://0.0.0.0/api/health && echo "Backend: OK" || echo "Backend: FAIL"

            echo ""
            echo "=== Frontend health check (via Nginx) ==="
            curl -sf http://0.0.0.0/health && echo "Frontend: OK" || echo "Frontend: FAIL"
EOF
log_success ".github/workflows/ci-cd.yml created."

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Files created:"
echo "  .github/workflows/ci-cd.yml"
echo ""

# ── Commit and push ───────────────────────────────────────────────────────────
read -r -p "Commit and push now to trigger the pipeline? [y/N] " confirm
if [[ "${confirm,,}" == "y" ]]; then
  git add .github/workflows/ci-cd.yml

  git commit -m "ci: update pipeline — single ECR repo, Ubuntu SSH user, Node 24"
  git push origin "$(git branch --show-current)"

  echo ""
  log_success "Pushed. Pipeline is running at:"

  REMOTE_URL=$(git remote get-url origin)
  if [[ "$REMOTE_URL" == git@* ]]; then
    GITHUB_REPO=$(echo "$REMOTE_URL" | sed 's/git@github.com://;s/\.git$//')
  else
    GITHUB_REPO=$(echo "$REMOTE_URL" | sed 's|https://github.com/||;s/\.git$//')
  fi
  echo ""
  echo "  https://github.com/${GITHUB_REPO}/actions"
  echo ""
else
  echo ""
  log_info "Skipped push. When ready, run:"
  echo ""
  echo "  git add .github/workflows/ci-cd.yml"
  echo "  git commit -m 'ci: update pipeline — single ECR repo, Ubuntu SSH user, Node 24'"
  echo "  git push origin main"
  echo ""
fi