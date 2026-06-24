EC2_IP=$(terraform output -raw ec2_public_ip)

# EC2 host
echo "$EC2_IP" | gh secret set EC2_HOST \
  --repo shubhamacharya/idurar-erp-crm

# Backend URL
echo "http://$EC2_IP:8888" | gh secret set BACKEND_PUBLIC_URL \
  --repo shubhamacharya/idurar-erp-crm

# SSH private key
terraform output -raw ssh_private_key \
  | gh secret set EC2_SSH_KEY \
      --repo shubhamacharya/idurar-erp-crm