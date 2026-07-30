terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }

  backend "s3" {
    bucket         = "dev-benchmark-tfstate-976902183321"
    key            = "aws-performance-benchmark/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "aws-perf-bench-tf-locks"
    encrypt        = true
  }
}
