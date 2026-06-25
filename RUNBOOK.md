# idurar ERP/CRM — Full Deployment Runbook
> From zero to running app on AWS Free Tier, step by step.
> Run each step in order. Confirm each before proceeding.

---

## Architecture

```
GitHub Push
    ↓
GitHub Actions (Lint → Build → Push to ECR → Deploy to EC2)
    ↓
EC2 t2.micro (Ubuntu 24.04)
    ├── Nginx (port 80)  → Frontend container (port 3000)
    └── Nginx /api/      → Backend container  (port 8888)
                                  ↓
                         MongoDB Atlas M0 (free)
```

---

## Prerequisites — Install Once

```bash
# Terraform
brew install terraform           # macOS
# OR
sudo apt install terraform       # Ubuntu

# AWS CLI
brew install awscli
# OR
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip awscliv2.zip && sudo ./aws/install

# GitHub CLI
brew install gh                  # macOS
# OR
sudo apt install gh              # Ubuntu

# Configure AWS credentials
aws configure
# Enter: Access Key ID, Secret Access Key
# Region: ap-south-1
# Output: json

# Authenticate GitHub CLI (one time)
gh auth login
# Choose: GitHub.com → HTTPS → Login with a web browser
```

---

## Phase 1 — MongoDB Atlas (Free Cluster)

Do this manually — Atlas M0 free tier has no Terraform support without billing.

```
1. Go to https://cloud.mongodb.com → Sign up / log in
2. Create project → name: "idurar"
3. Build a Database → M0 Free → AWS → Mumbai (ap-south-1)
4. Cluster name: idurar-cluster → Create (takes ~3 min)
```

After cluster is ready:

```
Security → Database Access → Add Database User
  Username : idurar-app
  Password : generate strong password — SAVE IT
  Role     : readWriteAnyDatabase

Security → Network Access → Add IP Address → 0.0.0.0/0
  (temporary — locked to EC2 IP after provisioning)

Clusters → Connect → Drivers → Node.js → Copy connection string:
  mongodb+srv://idurar-app:<PASSWORD>@idurar-cluster.xxxxx.mongodb.net/idurar
  Replace <PASSWORD> with actual password
```

**Save:** MongoDB URI — needed in terraform.tfvars

---

## Phase 2 — Terraform Infrastructure (ECR + IAM + Networking + EC2)

### Step 2.1 — Fill in terraform.tfvars

```bash
# Get your public IP
curl -s ifconfig.me

# Generate JWT secret (minimum 32 chars)
openssl rand -hex 32
```

Edit `terraform/terraform.tfvars`:

```hcl
aws_region   = "ap-south-1"
project_name = "idurar"
environment  = "production"
owner        = "shubham"
my_ip        = "YOUR_PUBLIC_IP"        # from curl ifconfig.me — SSH locked to this IP only
mongodb_uri  = "mongodb+srv://idurar-app:PASSWORD@idurar-cluster.xxxxx.mongodb.net/idurar"
jwt_secret   = "PASTE_OPENSSL_OUTPUT_HERE"
```

> ⚠️ Never commit terraform.tfvars — it is in .gitignore

### Step 2.2 — Apply ECR + IAM (no EC2 yet)

```bash
cd terraform/

terraform init

# Apply only ECR and IAM — EC2 comes after secrets are set
terraform apply \
  -target=module.registry \
  -target=module.iam
```

Confirm with `yes`. Takes ~30 seconds.

### Step 2.3 — Push Phase 2 secrets to GitHub

```bash
# From repo root
chmod +x scripts/push-secrets-to-github.sh
./scripts/push-secrets-to-github.sh
```

**What this sets:**

| Secret | Value |
|---|---|
| `AWS_REGION` | ap-south-1 |
| `ECR_REPO_URL` | 035694005905.dkr.ecr.ap-south-1.amazonaws.com/idurar |
| `AWS_ACCESS_KEY_ID` | from Terraform IAM output |
| `AWS_SECRET_ACCESS_KEY` | from Terraform IAM output |

> ℹ️ EC2 secrets are skipped at this stage — script detects they are not ready yet

### Step 2.4 — Trigger pipeline (Lint + Build + Push images to ECR)

```bash
# Workflow file must already be committed at .github/workflows/ci-cd.yml
git commit --allow-empty -m "ci: trigger ECR image build"
git push origin main
```

Watch live:
```bash
gh run watch --repo shubhamacharya/idurar-erp-crm
```

Pipeline flow:
```
✅ Lint & Test         (automatic)
⏸  Build & Push        (approve in GitHub → staging environment)
   → Approve → images pushed to ECR
⏸  Deploy to EC2       (paused — EC2 not provisioned yet, approve will fail)
   → REJECT this for now
```

Verify images in ECR:
```bash
aws ecr list-images \
  --repository-name idurar \
  --region ap-south-1 \
  --output table
```

Expected tags: `backend-latest`, `frontend-latest`, `backend-<sha>`, `frontend-<sha>`

---

## Phase 3 — Provision EC2

### Step 3.1 — Apply Networking + EC2

```bash
cd terraform/

# Networking first — EC2 depends on VPC + subnets
terraform apply -target=module.networking

# Then EC2 — generates SSH key, creates instance, runs bootstrap
terraform apply -target=module.ec2
```

Takes ~2 min. EC2 bootstrap (userdata) runs for another ~3-4 min after.

### Step 3.2 — Push Phase 3 secrets to GitHub

Run the same script again — it now detects EC2 outputs are available:

```bash
# From repo root
./scripts/push-secrets-to-github.sh
```

**What this additionally sets:**

| Secret | Value |
|---|---|
| `EC2_HOST` | EC2 public IP from terraform output |
| `BACKEND_PUBLIC_URL` | http://\<EC2_IP\>:8888 |
| `EC2_SSH_KEY` | SSH private key from terraform output (sensitive) |

> ℹ️ Script skips secrets that are already set with the same value

### Step 3.3 — Lock MongoDB Atlas to EC2 IP

```bash
EC2_IP=$(cd terraform && terraform output -raw ec2_public_ip)
echo "EC2 IP: $EC2_IP"
```

```
MongoDB Atlas → Security → Network Access
  → Edit 0.0.0.0/0
  → Replace with: <EC2_IP>/32
  → Confirm
```

### Step 3.4 — Verify EC2 bootstrap completed

```bash
cd terraform/

# SSH in using key from Terraform output
terraform output -raw ssh_private_key > /tmp/idurar-key.pem
chmod 600 /tmp/idurar-key.pem

EC2_IP=$(terraform output -raw ec2_public_ip)

# Tail bootstrap log
ssh -i /tmp/idurar-key.pem ubuntu@$EC2_IP \
  "sudo tail -30 /var/log/userdata.log"
```

Expected last lines:
```
====== idurar bootstrap complete at ...  ======
App running at: http://<EC2_IP>
Redeploy script created at /home/ubuntu/redeploy.sh
```

Check containers are running:
```bash
ssh -i /tmp/idurar-key.pem ubuntu@$EC2_IP \
  "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
```

Expected:
```
NAMES              STATUS          PORTS
idurar-backend     Up X minutes    0.0.0.0:8888->8888/tcp
idurar-frontend    Up X minutes    0.0.0.0:3000->80/tcp
```

---

## Phase 4 — Full Pipeline Run

### Step 4.1 — Trigger full 3-job pipeline

```bash
git commit --allow-empty -m "ci: trigger full deploy to EC2"
git push origin main
```

### Step 4.2 — Approve both gates

```
GitHub → Actions → latest run

Gate 1: staging environment
  → "Review deployments" → check staging → "Approve and deploy"
  → Images build and push to ECR

Gate 2: production environment
  → "Review deployments" → check production → "Approve and deploy"
  → SSH into EC2 → redeploy.sh runs → containers restart
```

Via CLI:
```bash
# List pending approvals
gh run list --repo shubhamacharya/idurar-erp-crm

# Approve (replace RUN_ID)
gh run review <RUN_ID> --approve --repo shubhamacharya/idurar-erp-crm
```

### Step 4.3 — Verify app is live

```bash
EC2_IP=$(cd terraform && terraform output -raw ec2_public_ip)

# Health checks via Nginx
curl -sf http://$EC2_IP/health       && echo "Nginx: OK"
curl -sf http://$EC2_IP/api/health   && echo "Backend: OK"

# Open in browser
echo "App: http://$EC2_IP"
```

---

## Phase 5 — Teardown (Free Tier safety)

When done testing, destroy everything to avoid charges:

```bash
cd terraform/

terraform destroy
# Type: yes
```

Destroys in this order automatically:
```
EC2 instance
Security Group
SSH Key Pair
SSM Parameters
IAM Role + Policy + Instance Profile
IAM User + Access Key
ECR repository + images
VPC + Subnets + IGW + Route Tables
CloudWatch Log Groups
```

> ℹ️ MongoDB Atlas M0 is free forever — no need to delete it
> ℹ️ GitHub Secrets persist — no need to re-run push-secrets after next apply
>    except for EC2_HOST which changes if EC2 is re-provisioned

---

## Re-apply from scratch (after destroy)

```bash
cd terraform/

terraform init

# Phase 2
terraform apply -target=module.registry -target=module.iam
./scripts/push-secrets-to-github.sh          # sets ECR + IAM secrets

# Trigger image build
git commit --allow-empty -m "ci: rebuild images"
git push origin main
# Approve staging gate — reject production gate (EC2 not ready)

# Phase 3
terraform apply -target=module.networking
terraform apply -target=module.ec2
./scripts/push-secrets-to-github.sh          # now also sets EC2 secrets

# Trigger full deploy
git commit --allow-empty -m "ci: full deploy"
git push origin main
# Approve both gates
```

---

## Script Changes — push-secrets-to-github.sh

Changes made from the original version:

| # | Change | Reason |
|---|---|---|
| 1 | `TERRAFORM_DIR` points to `terraform/` root (not `terraform/ecr/`) | Outputs now live at root module, not ECR submodule |
| 2 | Reads `ecr_repo_url` instead of `backend_repository_url` + `frontend_repository_url` | Single ECR repo now, two images differentiated by tag prefix |
| 3 | Sets `ECR_REPO_URL` secret instead of `ECR_BACKEND_URL` + `ECR_FRONTEND_URL` | Matches updated workflow env var |
| 4 | Added `--env production` flag to `gh secret set` | Secrets scoped to production environment, not repo-level |
| 5 | Phase 3 secrets (EC2_HOST, EC2_SSH_KEY, BACKEND_PUBLIC_URL) added | Combined script handles both phases |
| 6 | EC2 outputs read with `terraform output 2>/dev/null` fallback | Script safe to run after Phase 2 only — skips EC2 secrets gracefully |
| 7 | `AWS_REGION` hardcoded to `ap-south-1` instead of read from `terraform output` | Avoids output validation failure when EC2 module not yet applied |
| 8 | Auto-deletes `ECR_BACKEND_URL` + `ECR_FRONTEND_URL` if present | Cleanup stale secrets from old two-repo architecture |

---

## Security Notes

| Item | Current (Free Tier) | Production Hardening |
|---|---|---|
| EC2 SSH | Port 22 open to `my_ip` only | Remove entirely — use AWS SSM Session Manager |
| EC2 port 8888 | Open to `0.0.0.0/0` | Remove after adding ALB in Phase 5 — traffic via ALB only |
| MongoDB Atlas | `0.0.0.0/0` → locked to EC2 IP after provisioning | VPC peering or PrivateLink |
| JWT Secret | SSM SecureString | Same — already good |
| SSH Key | Terraform state (sensitive output) | AWS Secrets Manager |
| ECR | IAM user with access key | IAM role + OIDC (no long-lived keys) |

> ⚠️ EC2 port 8888 is currently open to the internet (0.0.0.0/0) for testing.
> This allows direct backend access bypassing Nginx.
> **Remove this ingress rule** once the app is verified working —
> all traffic should flow through Nginx on port 80 only.
> In Phase 5, port 8888 will be restricted to the ALB security group only.