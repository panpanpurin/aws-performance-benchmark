output "function_names" {
  description = "Map of app key to Lambda function name."
  value       = { for k, f in aws_lambda_function.app : k => f.function_name }
}

output "function_arns" {
  description = "Map of app key to Lambda function ARN."
  value       = { for k, f in aws_lambda_function.app : k => f.arn }
}

output "function_urls" {
  description = "Map of app key to Function URL (HTTPS)."
  value       = { for k, u in aws_lambda_function_url.app : k => u.function_url }
}
