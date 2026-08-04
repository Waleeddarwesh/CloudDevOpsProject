# ==============================================================================
# EKS Access Entries — mapping IAM identities to Kubernetes RBAC
# ==============================================================================
# Authenticating to an EKS cluster is a TWO-step process, and confusing the two
# is the most common source of "I have AdministratorAccess but kubectl says
# Unauthorized":
#
#   Step 1 — AWS IAM decides whether you may CALL the endpoint
#            (eks:DescribeCluster, and a signed SigV4 request).
#   Step 2 — Kubernetes RBAC decides what you may DO once inside.
#
# IAM permissions alone grant nothing inside the cluster. Something must map the
# IAM principal to a Kubernetes subject — historically the fragile aws-auth
# ConfigMap, where a single YAML typo locked everyone out permanently and
# irrecoverably.
#
# EKS Access Entries replace that ConfigMap with a real AWS API: declarative,
# validated, and visible in CloudTrail.
# ==============================================================================

# ------------------------------------------------------------------------------
# Cluster administrators
# ------------------------------------------------------------------------------
# NOTE: the identity that runs `terraform apply` is NOT listed here. It receives
# admin automatically via bootstrap_cluster_creator_admin_permissions in
# main.tf. Adding it again would fail with ResourceInUseException.
#
# Use var.cluster_admin_principals for teammates who also need kubectl access.
resource "aws_eks_access_entry" "admins" {
  for_each = toset(var.admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value

  # STANDARD = a human or CI identity. The other types (EC2_LINUX, FARGATE_LINUX)
  # are for node bootstrap and must not be used here.
  type = "STANDARD"

  tags = var.tags
}

resource "aws_eks_access_policy_association" "admins" {
  for_each = toset(var.admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value

  # Equivalent to the built-in cluster-admin ClusterRole.
  policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    # Cluster-wide, as opposed to "namespace" scope which would restrict the
    # grant to a named list of namespaces.
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admins]
}

# ------------------------------------------------------------------------------
# Jenkins CI
# ------------------------------------------------------------------------------
# Lets the pipeline run `kubectl rollout status` to confirm a deployment landed.
#
# Deliberately scoped to the `ivolve` namespace with EDIT rather than ADMIN:
#
#   * EDIT can read and modify workloads but cannot create/delete RBAC objects,
#     so a compromised pipeline cannot escalate its own privileges.
#   * Namespace scope means it cannot touch kube-system, argocd or monitoring.
#
# Least privilege matters most for automation, because a pipeline runs
# unattended and its credentials are reachable by anyone who can edit a
# Jenkinsfile.
resource "aws_eks_access_entry" "jenkins" {
  # Gated on a plain bool, NOT on `var.jenkins_role_arn != null`.
  # See the create_jenkins_access_entry variable for why: the ARN is unknown at
  # plan time, and `count` must be resolvable at plan time.
  count = var.create_jenkins_access_entry ? 1 : 0

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.jenkins_role_arn
  type          = "STANDARD"

  # Identity presented to Kubernetes RBAC. Shows up verbatim in the audit log,
  # so a `kubectl delete` traced back to this name is unambiguous.
  kubernetes_groups = ["ivolve-ci"]

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-jenkins-access"
  })
}

resource "aws_eks_access_policy_association" "jenkins" {
  count = var.create_jenkins_access_entry ? 1 : 0

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.jenkins_role_arn

  policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = "namespace"
    namespaces = ["ivolve"]
  }

  depends_on = [aws_eks_access_entry.jenkins]
}
