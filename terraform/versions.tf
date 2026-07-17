terraform {
  required_version = ">= 1.6.0"

  required_providers {
    # 依實際雲端平台取用對應 provider，預設示範 AWS
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # 遠端 state 後端（請依實際環境填入 bucket / key / region）
  backend "s3" {
    # 由 CI/CD 透過 -backend-config 動態注入，避免寫死
    # terraform init \
    #   -backend-config="bucket=$TF_STATE_BUCKET" \
    #   -backend-config="key=$TF_STATE_KEY" \
    #   -backend-config="region=$AWS_REGION"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "akaaka"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
