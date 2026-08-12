#!/usr/bin/env python3
"""
==============================================================================
generate_diagrams.py — architecture diagrams as code
==============================================================================

Generates the project's architecture diagrams from this script rather than by
hand, using the `diagrams` library (official AWS / Kubernetes / vendor icons,
laid out by Graphviz).

WHY THIS EXISTS
---------------
A hand-drawn diagram drifts. Every time it is re-exported or regenerated,
details silently change: an arrow appears between two services that never talk
to each other, a database gains a replica it does not have, a load balancer
starts routing through the CI server.

Here the arrows ARE code. They can be reviewed in a pull request, they diff
cleanly, and they cannot change unless someone edits this file. The topology
below was verified against the actual manifests:

    kubectl kustomize 04-Kubernetes/manifests

USAGE
-----
    pip install diagrams
    # plus the Graphviz *binary* (the pip package is only the bindings):
    #   Windows : winget install Graphviz.Graphviz
    #   macOS   : brew install graphviz
    #   Ubuntu  : sudo apt-get install graphviz

    python scripts/generate_diagrams.py

Writes PNGs to docs/diagrams/.

OUTPUT
------
    01-architecture-overview.png   the whole platform, end to end
    02-network-topology.png        VPC, subnets, gateways, traffic path
    03-cicd-pipeline.png           9 pipeline stages + the GitOps handoff
    04-kubernetes-runtime.png      namespace internals + the service graph
==============================================================================
"""

from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path

# ------------------------------------------------------------------------------
# Locate the Graphviz binary
# ------------------------------------------------------------------------------
# `pip install diagrams` pulls in the `graphviz` PYTHON package, which is only a
# set of bindings — it does NOT include the `dot` executable that actually
# renders the graph. On Windows the installer does not always add itself to PATH
# for the current session, so the common install locations are probed here.
# Without this the script fails with a bare "failed to execute WindowsPath('dot')".
_GRAPHVIZ_HINTS = [
    r"C:\Program Files\Graphviz\bin",
    r"C:\Program Files (x86)\Graphviz\bin",
    "/opt/homebrew/bin",
    "/usr/local/bin",
    "/usr/bin",
]

if shutil.which("dot") is None:
    for _hint in _GRAPHVIZ_HINTS:
        if Path(_hint, "dot.exe").exists() or Path(_hint, "dot").exists():
            os.environ["PATH"] = os.environ["PATH"] + os.pathsep + _hint
            break

if shutil.which("dot") is None:
    sys.exit(
        "ERROR: the Graphviz 'dot' binary was not found on PATH.\n"
        "       pip installs only the Python bindings; install the binary too:\n"
        "         Windows : winget install Graphviz.Graphviz\n"
        "         macOS   : brew install graphviz\n"
        "         Ubuntu  : sudo apt-get install graphviz"
    )

from diagrams import Cluster, Diagram, Edge  # noqa: E402

from diagrams.aws.compute import ECR, EKS, EC2  # noqa: E402
from diagrams.aws.management import Cloudwatch  # noqa: E402
from diagrams.aws.network import (  # noqa: E402
    ElbApplicationLoadBalancer,
    InternetGateway,
    NATGateway,
    PrivateSubnet,
    PublicSubnet,
    VPC,
)
from diagrams.aws.security import KMS, IAMRole  # noqa: E402
from diagrams.aws.storage import S3  # noqa: E402

from diagrams.k8s.clusterconfig import HPA, LimitRange  # noqa: E402
from diagrams.k8s.compute import Deploy, StatefulSet  # noqa: E402
from diagrams.k8s.network import Ingress, Service  # noqa: E402
from diagrams.k8s.podconfig import ConfigMap, Secret  # noqa: E402
from diagrams.k8s.rbac import ServiceAccount  # noqa: E402
from diagrams.k8s.storage import PVC, StorageClass  # noqa: E402

from diagrams.onprem.ci import Jenkins  # noqa: E402
from diagrams.onprem.container import Docker  # noqa: E402
from diagrams.onprem.client import Users  # noqa: E402
from diagrams.onprem.database import MySQL  # noqa: E402
from diagrams.onprem.gitops import ArgoCD  # noqa: E402
from diagrams.onprem.iac import Ansible, Terraform  # noqa: E402

# PrometheusOperator stands in for Alertmanager: the `diagrams` icon set has no
# dedicated Alertmanager glyph, and Alertmanager is a first-party component of
# the Prometheus project, so the family branding is accurate. Using the plain
# Prometheus icon for both would make the two nodes indistinguishable.
from diagrams.onprem.monitoring import Grafana, Prometheus, PrometheusOperator  # noqa: E402
from diagrams.onprem.security import Trivy  # noqa: E402
from diagrams.onprem.vcs import Github  # noqa: E402
from diagrams.saas.security import Sonarqube  # noqa: E402

# ------------------------------------------------------------------------------
# Output location and shared styling
# ------------------------------------------------------------------------------
PROJECT_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_DIR = PROJECT_ROOT / "docs" / "diagrams"
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

# Graphviz attributes applied to every diagram.
GRAPH_ATTR = {
    "fontsize": "26",
    "fontname": "Helvetica",
    "bgcolor": "white",
    "pad": "0.6",
    "splines": "spline",   # curved edges — far more readable than orthogonal
    "nodesep": "0.55",     # horizontal gap between sibling nodes
    "ranksep": "0.85",     # vertical gap between ranks
    "compound": "true",    # allows edges to terminate on cluster boundaries
}

NODE_ATTR = {"fontsize": "13", "fontname": "Helvetica"}
EDGE_ATTR = {"fontsize": "12", "fontname": "Helvetica"}

CLUSTER_ATTR = {"fontsize": "16", "fontname": "Helvetica-Bold", "margin": "18"}

# Semantic edge styles, so the meaning of a line is consistent everywhere.
#
# DATA    solid  — real traffic / real artefacts move along this edge
# CONTROL dashed — a controller observing or provisioning; NO traffic flows
# GITOPS  dashed — the reconciliation loop
DATA = Edge(color="#2563EB", penwidth="2.0")
CONTROL = Edge(color="#94A3B8", style="dashed", penwidth="1.6")
GITOPS = Edge(color="#16A34A", style="dashed", penwidth="1.8")
SECURITY = Edge(color="#DC2626", penwidth="2.0")


def _c(label: str, bg: str = "#F8FAFC", pencolor: str = "#475569") -> dict:
    """Cluster attributes with a background tint, for visual grouping."""
    attr = dict(CLUSTER_ATTR)
    attr.update({"bgcolor": bg, "pencolor": pencolor, "style": "rounded"})
    return attr


# ==============================================================================
# 1 — Architecture overview
# ==============================================================================
def architecture_overview() -> None:
    """The whole platform on one page: commit → build → gate → registry →
    Git → reconcile → run → observe."""

    with Diagram(
        "iVolve Cloud DevOps Capstone — Architecture Overview",
        filename=str(OUTPUT_DIR / "01-architecture-overview"),
        outformat="png",
        show=False,
        direction="LR",
        graph_attr=GRAPH_ATTR,
        node_attr=NODE_ATTR,
        edge_attr=EDGE_ATTR,
    ):
        developers = Users("Developers")
        end_users = Users("End Users\n(internet)")

        github = Github("GitHub\nCloudDevOpsProject")

        # ----------------------------------------------------------------------
        # Provisioning and configuration — runs once, before anything else
        # ----------------------------------------------------------------------
        with Cluster("Infrastructure as Code", graph_attr=_c("Infrastructure as Code", "#F5F3FF", "#7C3AED")):
            terraform = Terraform("Terraform\n4 modules")
            tfstate = S3("S3 backend\n(state + lock)")
            ansible = Ansible("Ansible\n9 roles")

            terraform >> CONTROL >> tfstate

        # ----------------------------------------------------------------------
        # Continuous integration
        # ----------------------------------------------------------------------
        with Cluster("CI — Jenkins EC2 (Ubuntu 22.04 · t3.medium)", graph_attr=_c("CI", "#FEF2F2", "#DC2626")):
            jenkins = Jenkins("Jenkins\nshared library")
            docker_build = Docker("Build\nmulti-stage")
            sonar = Sonarqube("SonarQube\nquality gate")
            trivy = Trivy("Trivy\nsecurity gate")

            jenkins >> DATA >> docker_build
            jenkins >> Edge(color="#DC2626", style="dashed", label="blocks") >> sonar
            docker_build >> SECURITY >> trivy

        registry = ECR("Amazon ECR\nimmutable tags")

        # ----------------------------------------------------------------------
        # Runtime
        # ----------------------------------------------------------------------
        with Cluster("AWS — EKS Cluster", graph_attr=_c("AWS", "#FFF7ED", "#EA580C")):
            alb = ElbApplicationLoadBalancer("ALB\ninternet-facing")

            with Cluster("namespace: ivolve", graph_attr=_c("ivolve", "#EFF6FF", "#2563EB")):
                ingress = Ingress("Ingress\n(alb class)")
                frontend = Deploy("frontend\nNode 22 · :3000")
                auth = Deploy("auth-service\nPython 3.12 · :5000")
                roadmap = Deploy("roadmap-service\nJava 21 · :8080")
                database = StatefulSet("mysql-0\nreplicas: 1")

                # ---- THE SERVICE GRAPH ----
                # Verified against 04-Kubernetes/manifests and enforced at
                # runtime by 6 NetworkPolicies with a default-deny baseline.
                #
                # Note what is ABSENT and must stay absent:
                #   * auth-service  ->  roadmap-service   (they never interact)
                #   * roadmap-service -> mysql            (it is stateless)
                #   * ALB -> Jenkins                      (CI is not in the path)
                ingress >> DATA >> frontend
                frontend >> Edge(color="#2563EB", penwidth="2.0", label=" :5000") >> auth
                frontend >> Edge(color="#2563EB", penwidth="2.0", label=" :8080") >> roadmap
                auth >> Edge(color="#2563EB", penwidth="2.0", label=" :3306") >> database

            alb >> DATA >> ingress

        # ----------------------------------------------------------------------
        # Continuous deployment
        # ----------------------------------------------------------------------
        with Cluster("GitOps", graph_attr=_c("GitOps", "#F0FDF4", "#16A34A")):
            argocd = ArgoCD("ArgoCD\nprune + selfHeal")

        # ----------------------------------------------------------------------
        # Observability
        # ----------------------------------------------------------------------
        with Cluster("Observability (in-cluster)", graph_attr=_c("Observability", "#FDF4FF", "#A21CAF")):
            prometheus = Prometheus("Prometheus")
            alertmanager = PrometheusOperator("Alertmanager")
            grafana = Grafana("Grafana")

            # Direction matters and is routinely drawn wrong:
            #   Prometheus PUSHES to Alertmanager when a rule fires.
            #   Grafana QUERIES Prometheus — it is a client, and is never
            #   in the alerting path.
            prometheus >> Edge(color="#A21CAF", label=" fires alert") >> alertmanager
            grafana >> Edge(color="#A21CAF", style="dashed", label=" queries") >> prometheus

        # ----------------------------------------------------------------------
        # The end-to-end flow
        # ----------------------------------------------------------------------
        developers >> DATA >> github
        github >> Edge(color="#DC2626", penwidth="2.0", label=" webhook") >> jenkins

        terraform >> CONTROL >> alb
        ansible >> Edge(color="#94A3B8", style="dashed", label=" configures") >> jenkins

        trivy >> Edge(color="#DC2626", penwidth="2.0", label=" passes gate") >> registry
        registry >> Edge(color="#EA580C", style="dashed", label=" image pull") >> frontend

        # The CI -> CD handoff. Jenkins commits; it never deploys.
        jenkins >> GITOPS >> github
        github >> Edge(color="#16A34A", style="dashed", label=" polls") >> argocd
        argocd >> Edge(color="#16A34A", penwidth="2.0", label=" syncs") >> ingress

        end_users >> DATA >> alb
        frontend >> Edge(color="#A21CAF", style="dotted", label=" scraped") >> prometheus


# ==============================================================================
# 2 — Network topology
# ==============================================================================
def network_topology() -> None:
    """VPC layout and the exact path a user request takes.

    The single most important thing this diagram gets right: the ALB routes
    into the cluster, NOT through the Jenkins server. Jenkins shares the public
    subnet but is not on the request path at all.
    """

    with Diagram(
        "Network Topology — VPC 10.0.0.0/16",
        filename=str(OUTPUT_DIR / "02-network-topology"),
        outformat="png",
        show=False,
        direction="TB",
        graph_attr=GRAPH_ATTR,
        node_attr=NODE_ATTR,
        edge_attr=EDGE_ATTR,
    ):
        internet = Users("Users\n(internet)")

        with Cluster("AWS Cloud", graph_attr=_c("AWS Cloud", "#FFF7ED", "#EA580C")):
            with Cluster("VPC  10.0.0.0/16", graph_attr=_c("VPC", "#FEFCE8", "#CA8A04")):
                igw = InternetGateway("Internet Gateway")

                with Cluster(
                    "Public Subnets  10.0.1.0/24 · 10.0.2.0/24",
                    graph_attr=_c("Public", "#F0FDF4", "#16A34A"),
                ):
                    alb = ElbApplicationLoadBalancer("ALB\ninternet-facing\ntarget-type: ip")
                    nat = NATGateway("NAT Gateway")
                    jenkins_ec2 = EC2("Jenkins EC2\nUbuntu 22.04 · t3.medium\n— CI ONLY —")

                with Cluster(
                    "Private Subnets  10.0.10.0/24 · 10.0.11.0/24  (multi-AZ)",
                    graph_attr=_c("Private", "#EFF6FF", "#2563EB"),
                ):
                    node_a = EKS("EKS worker\nAZ-a")
                    node_b = EKS("EKS worker\nAZ-b")

                # --- Inbound request path ---
                internet >> DATA >> igw
                igw >> DATA >> alb
                # Straight into the worker nodes' pods. Jenkins is deliberately
                # NOT on this path — it has no inbound edge from the ALB.
                alb >> Edge(color="#2563EB", penwidth="2.0", label=" pod IPs") >> node_a
                alb >> Edge(color="#2563EB", penwidth="2.0", label=" pod IPs") >> node_b

                # --- Outbound only, for the private subnets ---
                node_a >> Edge(color="#94A3B8", label=" egress") >> nat
                node_b >> Edge(color="#94A3B8", label=" egress") >> nat
                nat >> Edge(color="#94A3B8", label=" ECR / EKS API / OS updates") >> igw

                # Jenkins sits in a public subnet with an Elastic IP, so it
                # egresses through the IGW directly and never uses the NAT.
                jenkins_ec2 >> Edge(color="#94A3B8", style="dashed", label=" EIP · direct") >> igw

            with Cluster("Security & Audit", graph_attr=_c("Security", "#FEF2F2", "#DC2626")):
                flow_logs = Cloudwatch("VPC Flow Logs\n+ EKS audit")
                kms = KMS("KMS\nsecrets at rest")
                iam = IAMRole("OIDC + 3 IRSA roles\nno static keys")

            igw >> Edge(color="#DC2626", style="dotted", label=" ACCEPT/REJECT") >> flow_logs
            node_a >> Edge(color="#DC2626", style="dotted") >> kms
            node_a >> Edge(color="#DC2626", style="dotted") >> iam


# ==============================================================================
# 3 — CI/CD pipeline
# ==============================================================================
def cicd_pipeline() -> None:
    """The 9 pipeline stages and the GitOps handoff.

    The key architectural point: the pipeline ends at a Git commit. Jenkins
    holds no deployment credentials — ArgoCD, running inside the cluster,
    pulls the change.
    """

    with Diagram(
        "CI/CD Pipeline — 9 Stages + GitOps Handoff",
        filename=str(OUTPUT_DIR / "03-cicd-pipeline"),
        outformat="png",
        show=False,
        direction="LR",
        graph_attr=dict(GRAPH_ATTR, ranksep="1.0"),
        node_attr=NODE_ATTR,
        edge_attr=EDGE_ATTR,
    ):
        dev = Users("Developer")
        repo = Github("GitHub\nmain")

        with Cluster("Jenkins — per microservice", graph_attr=_c("Jenkins", "#FEF2F2", "#DC2626")):
            s1 = Jenkins("1 · Checkout\ntag = build-sha")
            s2 = Jenkins("2 · Unit Tests\ncontainerised")
            s3 = Sonarqube("3 · SonarQube\nquality gate")
            s4 = Docker("4 · Build Image\nmulti-stage")
            # NOTE: plain ASCII "=>" rather than the "⇒" arrow glyph. Graphviz
            # renders characters missing from the chosen font as a hollow box,
            # so any non-Latin-1 symbol in a label silently becomes "□".
            s5 = Trivy("5 · Scan Image\nCRITICAL => FAIL")
            s6 = ECR("6 · Push Image")
            s7 = Docker("7 · Delete Local")
            s8 = Jenkins("8 · Update Manifests\nkustomize set image")
            s9 = Github("9 · Push Manifests\n[skip ci]")

            (
                s1 >> DATA >> s2 >> DATA >> s3 >> DATA >> s4
                >> SECURITY >> s5 >> DATA >> s6 >> DATA >> s7 >> DATA >> s8 >> DATA >> s9
            )

        with Cluster("GitOps — ArgoCD (in cluster)", graph_attr=_c("GitOps", "#F0FDF4", "#16A34A")):
            argo = ArgoCD("ArgoCD\nautomated sync\nprune + selfHeal")
            cluster = EKS("EKS\nnamespace: ivolve")

            argo >> Edge(color="#16A34A", penwidth="2.0", label=" applies by wave") >> cluster

        dev >> DATA >> repo
        repo >> Edge(color="#DC2626", label=" webhook") >> s1

        # The handoff. Note the direction: ArgoCD PULLS from Git.
        # Jenkins never contacts the cluster.
        s9 >> GITOPS >> repo
        repo >> Edge(color="#16A34A", style="dashed", label=" polls / webhook") >> argo


# ==============================================================================
# 4 — Kubernetes runtime
# ==============================================================================
def kubernetes_runtime() -> None:
    """What actually runs inside the cluster: 37 rendered objects.

    Every edge here was verified against `kubectl kustomize` output and the
    NetworkPolicies that enforce it.
    """

    # direction="LR" is deliberate. With "TB" the four tiers stack into a
    # ~1:3 portrait image that is unreadable on screen; flowing the tiers
    # left-to-right (ingress -> frontend -> backend -> data) mirrors the
    # request path and keeps the aspect ratio close to landscape.
    with Diagram(
        "Kubernetes Runtime — namespace: ivolve",
        filename=str(OUTPUT_DIR / "04-kubernetes-runtime"),
        outformat="png",
        show=False,
        direction="LR",
        graph_attr=dict(GRAPH_ATTR, ranksep="1.1", nodesep="0.45"),
        node_attr=NODE_ATTR,
        edge_attr=EDGE_ATTR,
    ):
        alb = ElbApplicationLoadBalancer("ALB")

        with Cluster("kube-system", graph_attr=_c("kube-system", "#F1F5F9", "#64748B")):
            lb_controller = ServiceAccount("AWS Load Balancer\nController (IRSA)")

        with Cluster("namespace: ivolve", graph_attr=_c("ivolve", "#EFF6FF", "#2563EB")):
            ingress = Ingress("Ingress\n(alb class)\nroutes to frontend ONLY")

            with Cluster("Configuration", graph_attr=_c("Config", "#FEFCE8", "#CA8A04")):
                cm = ConfigMap("ConfigMap\nservice URLs")
                secret = Secret("Secret\nDB + session")

            with Cluster("Frontend tier", graph_attr=_c("Frontend", "#F0FDF4", "#16A34A")):
                svc_fe = Service("svc/frontend\nClusterIP")
                fe = Deploy("frontend\nNode 22 · :3000\nreplicas: 2")

            with Cluster("Backend tier", graph_attr=_c("Backend", "#FEF2F2", "#DC2626")):
                svc_auth = Service("svc/auth-service\nClusterIP")
                auth = Deploy("auth-service\nPython 3.12 · :5000")

                svc_road = Service("svc/roadmap-service\nClusterIP")
                road = Deploy("roadmap-service\nJava 21 · :8080\nSTATELESS")

            with Cluster("Data tier", graph_attr=_c("Data", "#F5F3FF", "#7C3AED")):
                svc_db = Service("svc/mysql\nheadless\nclusterIP: None")
                db = MySQL("mysql-0\nStatefulSet\nreplicas: 1")
                sc = StorageClass("StorageClass\nebs.csi.aws.com · gp3")
                pvc = PVC("PVC 10Gi\nWaitForFirstConsumer")

            with Cluster("Governance", graph_attr=_c("Governance", "#F8FAFC", "#475569")):
                hpa = HPA("HPA ×3")
                lr = LimitRange("LimitRange\n+ ResourceQuota")
                sa = ServiceAccount("ServiceAccounts ×4\nRole + RoleBinding ×2")

            # ------------------------------------------------------------------
            # THE SERVICE GRAPH — every edge verified
            # ------------------------------------------------------------------
            ingress >> DATA >> svc_fe >> DATA >> fe

            fe >> Edge(color="#2563EB", penwidth="2.0", label=" :5000") >> svc_auth
            svc_auth >> DATA >> auth

            fe >> Edge(color="#2563EB", penwidth="2.0", label=" :8080") >> svc_road
            svc_road >> DATA >> road

            # The ONLY path to the database. roadmap-service holds no DB
            # credentials and is blocked from :3306 by NetworkPolicy.
            auth >> Edge(color="#7C3AED", penwidth="2.0", label=" :3306") >> svc_db
            svc_db >> DATA >> db

            db >> Edge(color="#7C3AED", label=" volumeClaimTemplate") >> pvc
            pvc >> Edge(color="#7C3AED", style="dashed", label=" provisions") >> sc

            cm >> Edge(color="#CA8A04", style="dotted", label=" env") >> fe
            secret >> Edge(color="#CA8A04", style="dotted", label=" env") >> auth

            hpa >> Edge(color="#475569", style="dotted", label=" scales") >> fe

        # Control plane, not traffic: the controller reads the Ingress object
        # and provisions the ALB. No user request passes through it.
        alb >> DATA >> ingress
        lb_controller >> Edge(color="#94A3B8", style="dashed", label=" watches") >> ingress
        lb_controller >> Edge(color="#94A3B8", style="dashed", label=" provisions") >> alb


# ==============================================================================
# Entry point
# ==============================================================================
def main() -> int:
    diagrams_to_build = [
        ("Architecture overview", architecture_overview),
        ("Network topology", network_topology),
        ("CI/CD pipeline", cicd_pipeline),
        ("Kubernetes runtime", kubernetes_runtime),
    ]

    print(f"Rendering into {OUTPUT_DIR}\n")

    for label, fn in diagrams_to_build:
        print(f"  building  {label} ...", end=" ", flush=True)
        fn()
        print("done")

    print("\nGenerated:")
    for png in sorted(OUTPUT_DIR.glob("*.png")):
        print(f"  {png.name:<34} {png.stat().st_size / 1024:7.0f} KB")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
