# ─────────────────────────────────────────────
# AkaAka IaC – main entrypoint
# 在此宣告各 module 的呼叫；module 實作放在 modules/ 子目錄。
# ─────────────────────────────────────────────

# 範例 module 呼叫（尚未實作，取消註解後補上 modules/networking 即可啟用）：
#
# module "networking" {
#   source      = "./modules/networking"
#   environment = var.environment
#   project     = var.project
#   aws_region  = var.aws_region
# }
