#!/usr/bin/env bash
# =============================================================================
# setup-cicd.sh
#
# Places all CI/CD files into the correct locations in your idurar repo,
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
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ── Verify we are in the repo root ───────────────────────────────────────────
[[ -f "package.json" ]] || [[ -d "backend" && -d "frontend" ]] \
  || log_error "Run this script from the root of your idurar-erp-crm repo."

echo ""
echo "=============================================="
echo "  idurar CI/CD — file setup"
echo "=============================================="
echo ""

# ═════════════════════════════════════════════════════════════════════════════
# FILE CREATION
# Each heredoc writes a file exactly where it needs to live.
# ═════════════════════════════════════════════════════════════════════════════

# ── 1. GitHub Actions workflow ────────────────────────────────────────────────
# log_info "Creating .github/workflows/ci-cd.yml ..."
# mkdir -p .github/workflows

cat > .github/workflows/ci-cd.yml << 'EOF'
name: CI/CD Pipeline

on:
  push:
    branches: [main, master]
  pull_request:
    branches: [main, master]

env:
  AWS_REGION:       ${{ secrets.AWS_REGION }}
  ECR_BACKEND_URL:  ${{ secrets.ECR_BACKEND_URL }}
  ECR_FRONTEND_URL: ${{ secrets.ECR_FRONTEND_URL }}

jobs:

  # ── Job 1: Lint & Test ─────────────────────────────────────────────────────
  # Runs on every push AND every PR.
  # If this fails, build-and-push is skipped.
  lint-and-test:
    name: Lint & Test
    runs-on: ubuntu-latest

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Set up Node.js
        uses: actions/setup-node@v4
        with:
          node-version: "20"
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
          node-version: "20"
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
          VITE_BACKEND_URL: http://localhost:8888

  # ── Job 2: Build & Push to ECR ────────────────────────────────────────────
  # Runs only on push to main/master — never on PRs.
  # Depends on lint-and-test passing.
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
        id: ecr-login
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build backend image
        working-directory: backend
        run: |
          docker build \
            --tag ${{ env.ECR_BACKEND_URL }}:${{ steps.meta.outputs.tag }} \
            --tag ${{ env.ECR_BACKEND_URL }}:latest \
            --file Dockerfile \
            .

      - name: Push backend image
        run: |
          docker push ${{ env.ECR_BACKEND_URL }}:${{ steps.meta.outputs.tag }}
          docker push ${{ env.ECR_BACKEND_URL }}:latest

      - name: Build frontend image
        working-directory: frontend
        run: |
          docker build \
            --tag ${{ env.ECR_FRONTEND_URL }}:${{ steps.meta.outputs.tag }} \
            --tag ${{ env.ECR_FRONTEND_URL }}:latest \
            --file Dockerfile \
            --build-arg VITE_BACKEND_URL=${{ secrets.BACKEND_PUBLIC_URL }} \
            .

      - name: Push frontend image
        run: |
          docker push ${{ env.ECR_FRONTEND_URL }}:${{ steps.meta.outputs.tag }}
          docker push ${{ env.ECR_FRONTEND_URL }}:latest

      - name: Print image summary
        run: |
          echo "### Images pushed to ECR" >> $GITHUB_STEP_SUMMARY
          echo "| Image | Tag |" >> $GITHUB_STEP_SUMMARY
          echo "|---|---|" >> $GITHUB_STEP_SUMMARY
          echo "| Backend  | \`${{ steps.meta.outputs.tag }}\` |" >> $GITHUB_STEP_SUMMARY
          echo "| Frontend | \`${{ steps.meta.outputs.tag }}\` |" >> $GITHUB_STEP_SUMMARY

  # ── Job 3: Deploy (Phase 3 — uncomment when EC2 is ready) ─────────────────
  # deploy:
  #   name: Deploy to EC2
  #   runs-on: ubuntu-latest
  #   needs: build-and-push
  #   if: github.event_name == 'push'
  #   steps:
  #     - name: SSH into EC2 and redeploy
  #       uses: appleboy/ssh-action@v1
  #       with:
  #         host:     ${{ secrets.EC2_HOST }}
  #         username: ec2-user
  #         key:      ${{ secrets.EC2_SSH_KEY }}
  #         script: |
  #           cd /home/ec2-user/idurar-erp-crm
  #           aws ecr get-login-password --region ${{ secrets.AWS_REGION }} \
  #             | docker login --username AWS --password-stdin ${{ secrets.ECR_BACKEND_URL }}
  #           docker compose pull
  #           docker compose up -d --remove-orphans
EOF
log_success ".github/workflows/ci-cd.yml created."

# # ── 2. Backend Dockerfile ─────────────────────────────────────────────────────
# log_info "Creating backend/Dockerfile ..."

# # Backup existing Dockerfile if present
# [[ -f backend/Dockerfile ]] && cp backend/Dockerfile backend/Dockerfile.original \
#   && log_info "Existing backend/Dockerfile backed up to Dockerfile.original"

# cat > backend/Dockerfile << 'EOF'
# # ── Stage 1: deps ─────────────────────────────────────────────────────────────
# FROM node:20-alpine AS deps

# WORKDIR /app

# COPY package.json package-lock.json ./
# RUN npm ci --omit=dev

# # ── Stage 2: runtime ──────────────────────────────────────────────────────────
# FROM node:20-alpine AS runtime

# # Non-root user
# RUN addgroup -S appgroup && adduser -S appuser -G appgroup

# WORKDIR /app

# COPY --from=deps /app/node_modules ./node_modules
# COPY src/ ./src/
# COPY setup/ ./setup/
# COPY package.json ./

# RUN chown -R appuser:appgroup /app
# USER appuser

# EXPOSE 8888
# ENV NODE_ENV=production

# HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
#   CMD wget -qO- http://localhost:8888/api/health || exit 1

# CMD ["node", "src/app.js"]
# EOF
# log_success "backend/Dockerfile created."

# ── 3. Frontend Dockerfile ────────────────────────────────────────────────────
# log_info "Creating frontend/Dockerfile ..."

# [[ -f frontend/Dockerfile ]] && cp frontend/Dockerfile frontend/Dockerfile.original \
#   && log_info "Existing frontend/Dockerfile backed up to Dockerfile.original"

# cat > frontend/Dockerfile << 'EOF'
# # ── Stage 1: build ────────────────────────────────────────────────────────────
# FROM node:20-alpine AS build

# WORKDIR /app

# COPY package.json package-lock.json ./
# RUN npm ci

# COPY . .

# ARG VITE_BACKEND_URL
# ENV VITE_BACKEND_URL=$VITE_BACKEND_URL

# RUN npm run build

# # ── Stage 2: serve ────────────────────────────────────────────────────────────
# FROM nginx:1.27-alpine AS serve

# RUN rm /etc/nginx/conf.d/default.conf
# COPY nginx.conf /etc/nginx/conf.d/app.conf
# COPY --from=build /app/dist /usr/share/nginx/html

# EXPOSE 80

# HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
#   CMD wget -qO- http://localhost:80/health || exit 1

# CMD ["nginx", "-g", "daemon off;"]
# EOF
# log_success "frontend/Dockerfile created."

# ── 4. Nginx config ───────────────────────────────────────────────────────────
# log_info "Creating frontend/nginx.conf ..."

# cat > frontend/nginx.conf << 'EOF'
# server {
#     listen 80;
#     server_name _;

#     root /usr/share/nginx/html;
#     index index.html;

#     # Health check — used by Docker HEALTHCHECK and ALB in Phase 3
#     location /health {
#         access_log off;
#         return 200 "ok\n";
#         add_header Content-Type text/plain;
#     }

#     # Static assets — aggressive caching (Vite uses hashed filenames)
#     location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
#         expires 1y;
#         add_header Cache-Control "public, immutable";
#         try_files $uri =404;
#     }

#     # React Router SPA fallback — hard refresh on any route returns index.html
#     location / {
#         try_files $uri $uri/ /index.html;
#     }

#     # Security headers
#     add_header X-Frame-Options "SAMEORIGIN"     always;
#     add_header X-Content-Type-Options "nosniff" always;
#     add_header X-XSS-Protection "1; mode=block" always;
#     add_header Referrer-Policy "strict-origin"   always;

#     # Gzip
#     gzip on;
#     gzip_types text/plain text/css application/json application/javascript
#                text/xml application/xml text/javascript;
#     gzip_min_length 1024;
# }
# EOF
# log_success "frontend/nginx.conf created."

# ── 5. .dockerignore files ────────────────────────────────────────────────────
# log_info "Creating .dockerignore files ..."

# cat > backend/.dockerignore << 'EOF'
# node_modules
# .env
# *.variables.env
# *.log
# .git
# .gitignore
# README.md
# EOF

# cat > frontend/.dockerignore << 'EOF'
# node_modules
# dist
# .env
# *.log
# .git
# .gitignore
# README.md
# EOF
# log_success ".dockerignore files created."

# ═════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═════════════════════════════════════════════════════════════════════════════
# echo ""
# echo "Files created:"
# echo "  .github/workflows/ci-cd.yml"
# echo "  backend/Dockerfile"
# echo "  backend/.dockerignore"
# echo "  frontend/Dockerfile"
# echo "  frontend/.dockerignore"
# echo "  frontend/nginx.conf"
# echo ""

# ── 6. Commit and push ────────────────────────────────────────────────────────
read -r -p "Commit and push now to trigger the pipeline? [y/N] " confirm
if [[ "${confirm,,}" == "y" ]]; then
  git add \
    .github/workflows/ci-cd.yml \
    backend/Dockerfile \
    backend/.dockerignore \
    frontend/Dockerfile \
    frontend/.dockerignore \
    frontend/nginx.conf

  git commit -m "ci: add GitHub Actions pipeline and production Dockerfiles"
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
  echo "  git add .github backend/Dockerfile backend/.dockerignore frontend/Dockerfile frontend/.dockerignore frontend/nginx.conf"
  echo "  git commit -m 'ci: add GitHub Actions pipeline and production Dockerfiles'"
  echo "  git push origin main"
  echo ""
fi