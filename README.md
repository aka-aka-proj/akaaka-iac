# akaaka-iac

AkaAka 專案的 Infrastructure as Code（Terraform）。  
負責建立並管理所有雲端基礎設施，是整個發版鏈的第一層。

```
IaC (本 repo) ──► Backend ──► Frontend
```

---

## 目錄結構

```
.
├── .github/workflows/
│   ├── iac-ci.yml          # PR CI: fmt / validate / plan
│   └── iac-cd.yml          # main CD: staging apply → production apply（含人工審核）
├── docs/
│   └── release-order.md    # 整體發版順序說明
└── terraform/
    ├── versions.tf          # Terraform 版本與 Provider 宣告
    ├── variables.tf         # 輸入變數定義
    ├── outputs.tf           # 輸出值（供後續層使用）
    ├── main.tf              # 主要資源宣告（module 呼叫）
    ├── .gitignore
    └── envs/
        ├── staging/
        │   └── terraform.tfvars
        └── production/
            └── terraform.tfvars
```

---

## CI/CD 流程

### PR CI（`iac-ci.yml`）

觸發條件：`terraform/**` 有變更的 PR 到 main

| Job | 說明 |
|-----|------|
| `fmt` | `terraform fmt -check -recursive` |
| `validate` | `terraform validate`（local backend，不需憑證） |
| `plan-staging` | 對 staging 執行 plan，結果自動貼回 PR comment |

### Main CD（`iac-cd.yml`）

觸發條件：`terraform/**` 有變更合併進 main，或手動觸發

| Job | 說明 | 審核 |
|-----|------|------|
| `apply-staging` | 自動 apply staging | 無 |
| `apply-production` | apply production | **GitHub Environment 人工審核** |

---

## 初始設定清單

在 GitHub Repo Settings 完成以下設定後，CI/CD 即可正常運作：

### 1. GitHub Environments

至 **Settings → Environments** 建立：

| Environment | Protection Rules |
|-------------|-----------------|
| `staging` | （選填）可設 required reviewers 或 wait timer |
| `production` | **必要**：Required reviewers（至少 1 人） |

### 2. GitHub Secrets（依 Environment）

#### Environment: `staging`

| Secret 名稱 | 說明 |
|-------------|------|
| `AWS_ROLE_ARN_STAGING` | Staging 用 IAM Role ARN（OIDC）<br>例：`arn:aws:iam::123456789012:role/github-actions-staging` |
| `TF_STATE_BUCKET_STAGING` | Staging Terraform state S3 bucket 名稱 |

#### Environment: `production`

| Secret 名稱 | 說明 |
|-------------|------|
| `AWS_ROLE_ARN_PRODUCTION` | Production 用 IAM Role ARN（OIDC）<br>例：`arn:aws:iam::987654321098:role/github-actions-production` |
| `TF_STATE_BUCKET_PRODUCTION` | Production Terraform state S3 bucket 名稱 |

### 3. GitHub Variables（Repo 層級）

| Variable 名稱 | 說明 | 預設值 |
|--------------|------|--------|
| `AWS_REGION` | 部署目標 AWS Region | `ap-northeast-1` |

### 4. AWS OIDC 設定

在 AWS IAM 建立 OIDC Identity Provider 並設定對應 Role：

```hcl
# 範例：允許 GitHub Actions 承擔此 Role
data "aws_iam_policy_document" "github_actions_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = ["arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:aka-aka-proj/akaaka-iac:*"]
    }
  }
}
```

參考：[GitHub 官方 OIDC 文件](https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services)

---

## 本地開發

```bash
# 安裝 Terraform（建議使用 tfenv 管理版本）
tfenv install 1.9.5
tfenv use 1.9.5

# 初始化 staging 環境（需設定 AWS 憑證）
cd terraform
terraform init \
  -backend-config="bucket=<your-staging-bucket>" \
  -backend-config="key=akaaka/staging/terraform.tfstate" \
  -backend-config="region=ap-northeast-1"

# 格式化（PR 前必做）
terraform fmt -recursive

# 驗證
terraform validate

# Plan
terraform plan -var-file="envs/staging/terraform.tfvars"
```

---

## 相關文件

- [整體發版順序](./docs/release-order.md)
- [Terraform 官方文件](https://developer.hashicorp.com/terraform/docs)
