output "public_ip" {
  description = "Public IPv4 address of the server."
  value       = aws_instance.app.public_ip
}

output "ssh_command" {
  description = "SSH command for the server. It expects the private key at ~/.ssh/<key_name>.pem."
  value       = "ssh -i ~/.ssh/${var.key_name}.pem ubuntu@${aws_instance.app.public_ip}"
}
