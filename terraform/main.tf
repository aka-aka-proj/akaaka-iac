# Legacy notice:
# Terraform is no longer the primary deployment path for this repository.
# Active deployment uses Supabase + Vercel workflows.

# 範例 module 呼叫（尚未實作，取消註解後補上 modules/networking 即可啟用）：
#
# module "networking" {
#   source      = "./modules/networking"
#   environment = var.environment
#   project     = var.project
#   aws_region  = var.aws_region
# }
