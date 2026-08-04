# ==============================================================================
# Computed local values
# ==============================================================================
# Locals are evaluated once and reused, which keeps naming consistent across
# modules and gives a single place to change a convention.
# ==============================================================================

locals {
  # Every resource in the project is named "<project>-<environment>-<thing>",
  # e.g. ivolve-dev-vpc, ivolve-dev-jenkins, ivolve-dev-eks. This makes it
  # trivial to identify ownership in the console and to filter in Cost Explorer.
  name_prefix = "${var.project_name}-${var.environment}"

  # Referenced by the EKS module and by the subnet tags the AWS Load Balancer
  # Controller uses for discovery, so it must be computed once and shared.
  cluster_name = "${local.name_prefix}-eks"

  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name

  # The DNS name of this account's private registry.
  # Consumed by the Jenkins pipelines and by the Kubernetes image references.
  ecr_registry = "${local.account_id}.dkr.ecr.${local.region}.amazonaws.com"

  # Tags applied on top of the provider's default_tags. default_tags cannot use
  # values computed from other resources, so cluster-discovery tags live here.
  common_tags = {
    Cluster = local.cluster_name
  }
}
