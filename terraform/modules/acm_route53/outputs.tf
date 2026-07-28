output "certificate_arn" {
  description = "Validated certificate ARN."
  value       = aws_acm_certificate_validation.this.certificate_arn
}
