# AkaAka 整體發版順序

## 概覽

```
IaC (akaaka-iac) ──► Backend (akaaka-backend) ──► Frontend (akaaka-frontend)
```

各層之間存在**依賴關係**，下層就緒後上層才能部署。

---

## 詳細流程

### 1. IaC 層（本 Repo）

**目標**：建立/更新所有雲端基礎設施
**Repo**：`aka-aka-proj/akaaka-iac`

| 步驟 | 說明 |
|------|------|
| PR CI | `fmt` → `validate` → `plan`（貼回 PR comment） |
| Staging Apply | 合併 main 後自動執行 |
| Production Apply | Staging 成功後，等待 GitHub Environment 人工審核 |

**產出物（Terraform Outputs）**：
- VPC ID / Subnet IDs
- Security Group IDs
- RDS / ElastiCache endpoints
- ECS Cluster ARN / ALB DNS name
- S3 bucket names
- CloudFront distribution ID

---

### 2. Backend 層

**目標**：部署應用程式後端（API server、worker 等）
**前置條件**：IaC apply 完成，基礎設施就緒

**建議實作**：
```yaml
# backend workflow 中，於 IaC CD 完成後觸發
on:
  workflow_run:
    workflows: ["IaC CD – Apply (staging → production)"]
    types: [completed]
    branches: [main]
```

或由 IaC CD 最後一步呼叫：
```yaml
- name: Trigger backend deployment
  uses: actions/github-script@v7
  with:
    script: |
      await github.rest.actions.createWorkflowDispatch({
        owner: context.repo.owner,
        repo: 'akaaka-backend',
        workflow_id: 'deploy.yml',
        ref: 'main',
        inputs: { environment: 'staging' }
      });
```

---

### 3. Frontend 層

**目標**：部署靜態資源 / SSR 應用程式
**前置條件**：Backend 部署完成，API 端點可用

**建議實作**：
```yaml
# frontend workflow 在 backend 成功後觸發
on:
  workflow_run:
    workflows: ["Backend Deploy"]
    types: [completed]
    branches: [main]
```

---

## 環境映射

| GitHub Environment | 雲端環境 | 觸發方式 | 審核 |
|-------------------|---------|---------|------|
| `staging`         | AWS staging account / VPC | 自動（main push） | 無 |
| `production`      | AWS production account / VPC | staging 成功後 | **人工審核必要** |

---

## 緊急回滾

1. 找到上一個成功的 commit SHA
2. 至 GitHub Actions → `IaC CD` → `Run workflow`
3. 選擇 target 環境，在 terraform/ 中 `git revert` 問題 commit 並 push

---

## 相關連結

- [GitHub Environments 文件](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment)
- [AWS OIDC with GitHub Actions](https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services)
- [Terraform Remote State](https://developer.hashicorp.com/terraform/language/backend/s3)
