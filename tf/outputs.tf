output "mythic_mgmt_ip" {
  value = aws_instance.mythic.public_ip
}

output "stage_one_dns" {
  value = format("http://%s",aws_cloudfront_distribution.aws_cdn.domain_name)
}

output "stage_two_dns" {
  value = format("http://%s%s",var.azurecdn_name,".azureedge.net")
}
