# terraform/ec2/outputs.tf

output "ec2_public_ip" {
  description = "Public IP of the EC2 instance"
  value       = aws_instance.app.public_ip
}

output "ec2_instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.app.id
}

output "app_url" {
  description = "Frontend URL"
  value       = "http://${aws_instance.app.public_ip}"
}

output "backend_url" {
  description = "Backend API URL"
  value       = "http://${aws_instance.app.public_ip}:8888"
}

output "ssh_private_key" {
  description = "EC2 SSH private key — pipe to a file to use"
  value       = tls_private_key.ec2_key.private_key_openssh
  sensitive   = true
}

output "ssh_command" {
  description = "One-liner to fetch key from Terraform and SSH in"
  value       = "terraform output -raw ssh_private_key > /tmp/idurar-key.pem && chmod 600 /tmp/idurar-key.pem && ssh -i /tmp/idurar-key.pem ubuntu@${aws_instance.app.public_ip}"
}
