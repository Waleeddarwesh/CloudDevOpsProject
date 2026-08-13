# ==============================================================================
# Root module — composes the four infrastructure modules
# ==============================================================================
# Terraform builds a dependency graph from the references between these modules
# and parallelises everything that is independent. Note there is no `depends_on`
# anywhere below: passing `module.network.vpc_id` into another module IS the
# dependency declaration, and it is more precise than a blanket depends_on.
#
# Resulting order:
#
#     network ──┬──► server (Jenkins EC2 in a public subnet)
#               └──► eks    (worker nodes in private subnets)
#     ecr       (independent — no VPC dependency, created in parallel)
# ==============================================================================

locals {
  # Automatically parse the IP address straight from the .env file in the project root!
  # This guarantees no IP is ever hardcoded in the Terraform files.
  env_file      = try(file("${path.module}/../.env"), "")
  ip_matches    = regexall("USER_PUBLIC_IP=([^\\r\\n]+)", local.env_file)
  dynamic_ip    = length(local.ip_matches) > 0 ? trimspace(local.ip_matches[0][0]) : "0.0.0.0"
  dynamic_cidrs = ["${local.dynamic_ip}/32"]
}

# ------------------------------------------------------------------------------
# 1. Network — VPC, subnets, IGW, NAT, route tables, NACLs, flow logs
# ------------------------------------------------------------------------------
module "network" {
  source = "./modules/network"

  name_prefix = local.name_prefix
  vpc_cidr    = var.vpc_cidr

  availability_zones   = var.availability_zones
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs

  single_nat_gateway = var.single_nat_gateway

  enable_flow_logs         = var.enable_flow_logs
  flow_logs_retention_days = var.flow_logs_retention_days

  # Passed in — not read back from the EKS module — to avoid a dependency cycle.
  # The subnets must carry the cluster discovery tag before the cluster exists,
  # because EKS validates those tags while creating the cluster.
  cluster_name = local.cluster_name

  tags = local.common_tags
}

# ------------------------------------------------------------------------------
# 2. Server — Jenkins EC2 instance, Security Group, IAM instance profile
# ------------------------------------------------------------------------------
module "server" {
  source = "./modules/server"

  name_prefix = local.name_prefix
  vpc_id      = module.network.vpc_id

  # Public subnet: Jenkins needs an inbound route for the web UI and for GitHub
  # webhooks, which a private subnet cannot provide without extra plumbing.
  subnet_id = module.network.public_subnet_ids[0]

  instance_type    = var.jenkins_instance_type
  root_volume_size = var.jenkins_root_volume_size
  key_name         = var.key_name

  allowed_ssh_cidrs        = local.dynamic_cidrs
  allowed_jenkins_ui_cidrs = local.dynamic_cidrs
  enable_sonarqube         = var.enable_sonarqube

  # Granted to the instance profile so Jenkins can `docker push` to ECR and run
  # `aws eks update-kubeconfig` — with no static access keys stored on the box.
  ecr_repository_arns = module.ecr.repository_arns

  # The cluster NAME is passed (from locals) rather than the cluster ARN read
  # back from module.eks. Referencing module.eks here would create a dependency
  # cycle, because module.eks already consumes module.server.iam_role_arn to
  # build its EKS Access Entry. The server module reconstructs the ARN itself
  # from account + region + name, which is deterministic and known at plan time.
  eks_cluster_name = local.cluster_name

  tags = local.common_tags
}

# ------------------------------------------------------------------------------
# 3. EKS — control plane, managed node group, OIDC provider, addons, IRSA roles
# ------------------------------------------------------------------------------
module "eks" {
  source = "./modules/eks"

  cluster_name       = local.cluster_name
  kubernetes_version = var.kubernetes_version

  # No vpc_id is passed: EKS infers the VPC from the subnets below.

  # Worker nodes go in the PRIVATE subnets. They have no public IP and reach the
  # internet only via the NAT Gateway, so a compromised pod cannot be reached
  # directly from the internet.
  private_subnet_ids = module.network.private_subnet_ids

  # The control plane also attaches ENIs in the public subnets so that the
  # public API endpoint and internet-facing load balancers work.
  public_subnet_ids = module.network.public_subnet_ids

  node_instance_types = var.node_instance_types
  node_desired_size   = var.node_desired_size
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size
  node_disk_size      = var.node_disk_size

  endpoint_public_access_cidrs = local.dynamic_cidrs
  cluster_log_types            = var.cluster_log_types

  # Extra IAM principals granted cluster-admin via EKS Access Entries.
  #
  # The identity that runs `terraform apply` is NOT listed here — it is granted
  # admin automatically by bootstrap_cluster_creator_admin_permissions inside
  # the module. That is deliberate: when Terraform runs under an assumed role,
  # aws_caller_identity returns a session ARN
  # (arn:aws:sts::…:assumed-role/Role/session) which the Access Entry API
  # rejects, so building an entry from it would break every CI-driven apply.
  admin_principal_arns = var.cluster_admin_principals

  # Lets the Jenkins instance role authenticate to the cluster for the
  # (optional) rollout-verification stage in the pipeline.
  jenkins_role_arn = module.server.iam_role_arn

  tags = local.common_tags
}

# ------------------------------------------------------------------------------
# 4. ECR — one private image repository per microservice
# ------------------------------------------------------------------------------
module "ecr" {
  source = "./modules/ecr"

  name_prefix      = local.name_prefix
  repository_names = var.ecr_repository_names

  image_retention_count = var.ecr_image_retention_count
  force_delete          = var.ecr_force_delete

  tags = local.common_tags
}
