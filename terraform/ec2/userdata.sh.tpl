#!/bin/bash
# =============================================================================
# userdata.sh.tpl
#
# Runs ONCE at first boot as root on the EC2 instance.
# Terraform renders this template with actual values before passing to EC2.
#
# Template vars injected by Terraform:
#   ${aws_region}    — e.g. ap-south-1
#   ${project_name}  — e.g. idurar
#   ${environment}   — e.g. production
#   ${ecr_repo_url}  — e.g. 035694005905.dkr.ecr.ap-south-1.amazonaws.com/idurar
#   ${account_id}    — e.g. 035694005905
#
# Image tag convention (single ECR repo, two images):
#   backend  → ${ecr_repo_url}:backend-latest
#   frontend → ${ecr_repo_url}:frontend-latest
# =============================================================================

set -euo pipefail
exec > >(tee /var/log/userdata.log | logger -t userdata) 2>&1

echo "====== idurar bootstrap starting at $(date) ======"

# ── 1. System update ──────────────────────────────────────────────────────────
# Ubuntu 24.04 uses apt, not dnf
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y

# ── 2. Install dependencies ───────────────────────────────────────────────────
apt-get install -y curl unzip nginx

# ── 3. Install Docker (Ubuntu 24.04 method) ───────────────────────────────────
# Docker is NOT in Ubuntu's default apt repo — must add Docker's official repo
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io

systemctl enable --now docker
usermod -aG docker ubuntu   # ubuntu is the default user on Ubuntu AMIs, not ec2-user

# ── 4. Install AWS CLI v2 ─────────────────────────────────────────────────────
# Ubuntu 24.04 AMI does not ship AWS CLI — install manually
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
  -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp/
/tmp/aws/install
rm -rf /tmp/awscliv2.zip /tmp/aws
echo "AWS CLI: $(aws --version)"

# ── 5. Log in to ECR ─────────────────────────────────────────────────────────
# IAM role attached to this EC2 provides credentials — no access key needed
aws ecr get-login-password --region ${aws_region} \
  | docker login \
      --username AWS \
      --password-stdin \
      "${account_id}.dkr.ecr.${aws_region}.amazonaws.com"
echo "ECR login successful."

# ── 6. Read secrets from SSM Parameter Store ──────────────────────────────────
MONGODB_URI=$(aws ssm get-parameter \
  --name "/${project_name}/${environment}/MONGODB_URI" \
  --with-decryption \
  --region ${aws_region} \
  --query "Parameter.Value" \
  --output text)

JWT_SECRET=$(aws ssm get-parameter \
  --name "/${project_name}/${environment}/JWT_SECRET" \
  --with-decryption \
  --region ${aws_region} \
  --query "Parameter.Value" \
  --output text)

PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
echo "Secrets read from SSM successfully."

# ── 7. Create Docker network ──────────────────────────────────────────────────
docker network create idurar-net 2>/dev/null || true

# ── 8. Pull images from ECR ───────────────────────────────────────────────────
# Single ECR repo — two images differentiated by tag prefix
echo "Pulling backend image..."
docker pull ${ecr_repo_url}:backend-latest

echo "Pulling frontend image..."
docker pull ${ecr_repo_url}:frontend-latest

# ── 9. Stop and remove old containers if re-running ──────────────────────────
docker rm -f idurar-backend  2>/dev/null || true
docker rm -f idurar-frontend 2>/dev/null || true

# ── 10. Start backend container ───────────────────────────────────────────────
docker run -d \
  --name idurar-backend \
  --network idurar-net \
  --restart unless-stopped \
  -p 8888:8888 \
  -e NODE_ENV=production \
  -e DATABASE="$MONGODB_URI" \
  -e JWT_SECRET="$JWT_SECRET" \
  -e PORT=8888 \
  --log-driver awslogs \
  --log-opt awslogs-region=${aws_region} \
  --log-opt awslogs-group=/idurar/backend \
  --log-opt awslogs-create-group=true \
  ${ecr_repo_url}:backend-latest

echo "Backend container started."

# ── 11. Start frontend container ──────────────────────────────────────────────
docker run -d \
  --name idurar-frontend \
  --network idurar-net \
  --restart unless-stopped \
  -p 3000:80 \
  --log-driver awslogs \
  --log-opt awslogs-region=${aws_region} \
  --log-opt awslogs-group=/idurar/frontend \
  --log-opt awslogs-create-group=true \
  ${ecr_repo_url}:frontend-latest

echo "Frontend container started."

# ── 12. Configure Nginx reverse proxy ─────────────────────────────────────────
# Ubuntu nginx uses sites-available/sites-enabled, not conf.d
cat > /etc/nginx/sites-available/idurar.conf << 'NGINXCONF'
server {
    listen 80;
    server_name _;

    # Health check — for future ALB target group
    location /health {
        access_log off;
        return 200 "ok\n";
        add_header Content-Type text/plain;
    }

    # Backend API
    location /api/ {
        proxy_pass         http://localhost:8888;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_read_timeout 60s;
    }

    # Frontend React app
    location / {
        proxy_pass         http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
    }
}
NGINXCONF

ln -sf /etc/nginx/sites-available/idurar.conf /etc/nginx/sites-enabled/idurar.conf
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl enable --now nginx
systemctl reload nginx

echo "====== idurar bootstrap complete at $(date) ======"
echo "App running at: http://$PUBLIC_IP"

# ── 13. Create redeploy script ────────────────────────────────────────────────
# GitHub Actions SSHes in as 'ubuntu' and calls this on every deploy.
cat > /home/ubuntu/redeploy.sh << 'REDEPLOY'
#!/bin/bash
set -euo pipefail

AWS_REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
ECR_REPO_URL="$ECR_REGISTRY/idurar"

echo "[redeploy] Logging in to ECR..."
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"

echo "[redeploy] Pulling latest images..."
docker pull "$ECR_REPO_URL":backend-latest
docker pull "$ECR_REPO_URL":frontend-latest

echo "[redeploy] Restarting containers..."
docker restart idurar-backend
docker restart idurar-frontend

echo "[redeploy] Done. Running containers:"
docker ps --filter "name=idurar" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
REDEPLOY

chmod +x /home/ubuntu/redeploy.sh
chown ubuntu:ubuntu /home/ubuntu/redeploy.sh
echo "Redeploy script created at /home/ubuntu/redeploy.sh"
