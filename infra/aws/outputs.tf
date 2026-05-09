output "instance_id" {
  description = "EC2 instance ID."
  value       = aws_instance.app.id
}

output "public_ip" {
  description = "Public IP to open in a browser."
  value       = var.create_eip ? aws_eip.app[0].public_ip : aws_instance.app.public_ip
}

output "app_url" {
  description = "HTTP URL served by Nginx."
  value       = "http://${var.create_eip ? aws_eip.app[0].public_ip : aws_instance.app.public_ip}"
}

output "ssh_command" {
  description = "SSH command for the Ubuntu host, if key_name and ssh_cidr_blocks were configured."
  value = (
    var.key_name != "" && length(var.ssh_cidr_blocks) > 0
    ? "ssh ubuntu@${var.create_eip ? aws_eip.app[0].public_ip : aws_instance.app.public_ip}"
    : "SSH is not enabled by default. Set key_name and ssh_cidr_blocks to enable it."
  )
}
