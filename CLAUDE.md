# NexusPlay — Project Notes

## Lab environment (AWS Academy Learner Lab, account 534883687114, us-east-1)

### Discovered constraints (from live probing 2026-07-07)

- **Region:** us-east-1 only.
- **EC2 key pair:** `vockey` (file `labsuser.pem`).
- **IAM:** Cannot create users, groups, roles, or policies. Must use the pre-created **`LabRole`** (service role) and **`LabInstanceProfile`** (EC2 instance profile). No custom KMS keys — use default `aws/ssm`.
- **LabRole trust principals — important omissions:** LabRole trusts `codedeploy.amazonaws.com` and `codecommit.amazonaws.com` but **NOT `codebuild.amazonaws.com` or `codepipeline.amazonaws.com`**. So **CodePipeline and CodeBuild cannot be used** as services in this lab (they cannot assume LabRole, and no new role can be created).
- **LabRole permissions:** `AmazonSSMManagedInstanceCore`, `AmazonEC2ContainerRegistryReadOnly` (ECR read only, no push), `AmazonEKSClusterPolicy`, `AmazonEKSWorkerNodePolicy`, plus three `VocLabPolicy{1,2,3}` managed policies (broad lab permissions).
- **ECR push must use `voclabs` CLI principal** (the session role used by the AWS CLI), not LabRole. Therefore build+push steps in CI/CD must run with voclabs credentials (CLI or GitHub Actions with stored creds). EC2 instances and Lambdas (assuming LabRole) can only pull.
- **EC2 hard limits:** ≤ 9 instances concurrently, ≤ 32 vCPU, t3.nano/large only, Amazon Linux 2023 AMIs only, EBS ≤ 100GB gp2/gp3.
- **RDS:** single-AZ only (Multi-AZ disabled), `db.t3.nano–medium`, engines Aurora/MySQL/PostgreSQL/MariaDB, no enhanced monitoring.
- **ALB:** requires subnets in ≥ 2 AZs at creation; we create it across two default-VPC subnets (`us-east-1a` + `us-east-1b`) but register targets only in `us-east-1a`.
- **Default VPC:** `vpc-06d792aa2b5ae6ed5` (172.31.0.0/16), IGW `igw-0e74ceaf657a9b875`. Default subnets in us-east-1a–f.
- **AZ choice:** `us-east-1a` = `subnet-073d3faa9c0fda772`, `us-east-1b` = `subnet-091bd6a245f6d438f`.
- **Instances:** launched without public IP; admin access via SSM Session Manager through VPC interface endpoints.

### CI/CD strategy

Because CodePipeline/CodeBuild are unavailable, **CI/CD = GitHub Actions** on `Asquadia/dark-project`:
- Trigger on push to `main`.
- Jobs: `build-and-push` (ECR login + docker build/push with voclabs creds) → `deploy` (update ASG launch template to new image tag + `start-instance-refresh`) → `loadtest` (k6 with thresholds, gates the workflow).
- AWS creds stored as GitHub Actions secrets (must be refreshed on lab restart — documented in POC report).
- Until GitHub credentials are available locally, the pipeline logic is exercised via equivalent `scripts/ci-*.sh` commands.

### Access model

- All EC2 instances: **no public IP**, `LabInstanceProfile`, SSM Session Manager for admin access via VPC interface endpoints.
- No SSH key required at runtime; `labsuser.pem` kept as backup (and stored locally — never committed).
- All cross-component addressing by **DNS name** (BIND zone `nexusplay.lab`) or by **Name-tag discovery** at boot, never by IP literal.

## Plan file

The full implementation plan lives at `/home/ascadia/.claude/plans/glittery-bubbling-tiger.md`.