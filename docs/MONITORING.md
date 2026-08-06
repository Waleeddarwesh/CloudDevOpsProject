# 📊 Monitoring & Observability

Metrics architecture, the alert catalogue, and the white-box upgrade path.

For installation see [Phase 7](../07-Monitoring/README.md). For responding to a firing alert see [RUNBOOK.md](RUNBOOK.md).

---

## 📑 Contents

- [Metrics Architecture](#metrics-architecture)
- [The White-box Gap](#the-white-box-gap)
- [Alert Catalogue](#alert-catalogue)
- [Alert Design Principles](#alert-design-principles)
- [Useful PromQL](#useful-promql)
- [Dashboards](#dashboards)
- [Retention and Cost](#retention-and-cost)
- [Upgrade Path](#upgrade-path)

---

<a id="metrics-architecture"></a>

## 🏗️ Metrics Architecture

```text
   ┌─────────────────────────────────────────────────────────┐
   │                     Prometheus                          │
   │  scrape every 30s · store 15d/8GB · evaluate 12 rules   │
   └──┬────────────┬──────────────┬─────────────┬────────────┘
      │            │              │             │
      ▼            ▼              ▼             ▼
 ┌─────────┐ ┌───────────┐ ┌───────────┐ ┌────────────┐
 │ node-   │ │ kube-     │ │ blackbox- │ │ kubelet /  │
 │ exporter│ │ state-    │ │ exporter  │ │ cAdvisor   │
 │         │ │ metrics   │ │           │ │            │
 │DaemonSet│ │Deployment │ │Deployment │ │ on nodes   │
 └─────────┘ └───────────┘ └───────────┘ └────────────┘
   HOST        OBJECT         USER          CONTAINER
   CPU/mem     replica        can it        per-pod
   disk/net    counts,        actually      cpu/mem/
               pod phase      serve?        net
      │            │              │             │
      └────────────┴──────┬───────┴─────────────┘
                          ▼
              ┌───────────────────────┐
              │ Alertmanager  Grafana │
              └───────────────────────┘
```

### What each source answers

| Source | Question it answers | Example metric |
|---|---|---|
| **node-exporter** | Is the *machine* healthy? | `node_memory_MemAvailable_bytes` |
| **kube-state-metrics** | Is the *orchestration* correct? | `kube_deployment_status_replicas_available` |
| **cAdvisor** (kubelet) | What is each *container* consuming? | `container_cpu_cfs_throttled_periods_total` |
| **blackbox-exporter** | Can a *user* actually use it? | `probe_success` |

> 💡 All four are needed. A node can be perfectly healthy while every pod on it is `CrashLoopBackOff`. A Deployment can report `3/3 Ready` while the application returns 500 to every request. Only the black-box probe catches the second case.

### node-exporter must be a DaemonSet

```text
   DaemonSet                          Deployment replicas: 2
┌──────────────────────────────┐   ┌────────────────────────────────┐
│ node-1 ──► exporter          │   │ node-1 ──► exporter × 2         │
│ node-2 ──► exporter          │   │ node-2 ──► (none)               │
│ node-3 ──► exporter  ← added │   │                                 │
│            automatically     │   │ ✗ node-2 unmonitored, silently  │
└──────────────────────────────┘   └────────────────────────────────┘
```

And it must tolerate every taint:

```yaml
tolerations:
  - operator: Exists
```

Without this, a node tainted `workload=database:NoSchedule` gets no exporter and its metrics simply vanish — with no error anywhere.

---

<a id="the-white-box-gap"></a>

## 🔍 The White-box Gap

**This is the most important design decision in this phase, and it is a documented trade-off, not an oversight.**

None of the three microservices expose Prometheus metrics:

| Service | Why not |
|---|---|
| `frontend` | Express, no `prom-client` dependency |
| `auth-service` | Flask, no `prometheus_flask_exporter` |
| `roadmap-service` | Spring Boot **without** `spring-boot-starter-actuator` — the POM declares only `spring-boot-starter-web` |

A `ServiceMonitor` would therefore have nothing to scrape.

### The choice

```text
   White-box                            Black-box (chosen)
┌──────────────────────────────┐   ┌────────────────────────────────────┐
│ requires modifying src/      │   │ zero application changes           │
│                              │   │                                    │
│ ✓ request rate by route      │   │ ✓ availability                     │
│ ✓ error rate by status code  │   │ ✓ end-to-end latency               │
│ ✓ latency histograms (p50/99)│   │ ✓ status code correctness          │
│ ✓ GC, thread pools, JDBC     │   │ ✗ no internal detail               │
│ ✓ business counters          │   │ ✗ no per-route breakdown           │
└──────────────────────────────┘   └────────────────────────────────────┘
```

Black-box was chosen so `src/` stays **byte-identical to upstream commit `aa60d92`** and can be independently verified against the original repository. It also answers the more direct operational question: *can a user actually log in right now?*

### What is measured today

```promql
probe_success{service="frontend"}          # 1 = HTTP 2xx, 0 = failing
probe_duration_seconds{service="frontend"} # end-to-end response time
probe_http_status_code{service="frontend"} # the actual status code
```

Probed endpoints — **cluster-internal**, deliberately:

| Service | Probed URL |
|---|---|
| `frontend` | `http://frontend.ivolve.svc.cluster.local:80/` |
| `auth-service` | `http://auth-service.ivolve.svc.cluster.local:5000/health` |
| `roadmap-service` | `http://roadmap-service.ivolve.svc.cluster.local:8080/api/roadmap` |

> 💡 Probing the internal Service rather than the public ALB **isolates application health from load-balancer health**. If the internal probe passes but users report errors, the problem is the ALB, DNS or the target group — not the application. That distinction saves a lot of time during an incident.

---

<a id="alert-catalogue"></a>

## 🔔 Alert Catalogue

| Alert | Sev | `for:` | Expression (abbreviated) | Runbook |
|---|:---:|:---:|---|---|
| `IvolveServiceDown` | 🔴 | 2m | `probe_success == 0` | [→](RUNBOOK.md#service-down) |
| `IvolveServiceSlow` | 🟡 | 5m | `probe_duration_seconds > 2` | [→](RUNBOOK.md#service-slow) |
| `IvolvePodCrashLooping` | 🔴 | 5m | `rate(restarts_total[15m]) * 900 > 3` | [→](RUNBOOK.md#crashloopbackoff) |
| `IvolveDeploymentReplicasMismatch` | 🟡 | 15m | `spec_replicas != status_replicas_available` | [→](RUNBOOK.md#replicas-mismatch) |
| `IvolvePodNotReady` | 🟡 | 10m | `kube_pod_status_phase{phase=~"Pending\|Unknown"} > 0` | [→](RUNBOOK.md#pod-pending) |
| `IvolveMySQLDown` | 🔴 | 2m | `kube_statefulset_status_replicas_ready{statefulset="mysql"} == 0` | [→](RUNBOOK.md#mysql-down) |
| `IvolveDatabaseVolumeFillingUp` | 🟡 | 1h | `predict_linear(available_bytes[6h], 4d) < 0` | [→](RUNBOOK.md#disk-filling-up) |
| `IvolveContainerCPUThrottling` | 🟡 | 10m | `throttled_periods / periods > 0.25` | [→](RUNBOOK.md#cpu-throttling) |
| `IvolveContainerMemoryNearLimit` | 🟡 | 10m | `working_set / limit > 0.90` | [→](RUNBOOK.md#memory-near-limit) |
| `IvolveNodeNotReady` | 🔴 | 5m | `kube_node_status_condition{condition="Ready"} == 0` | [→](RUNBOOK.md#node-notready) |
| `IvolveNodeDiskPressure` | 🟡 | 5m | `condition="DiskPressure" == 1` | [→](RUNBOOK.md#node-disk-pressure) |
| `IvolveNodeHighMemory` | 🟡 | 10m | `1 - (MemAvailable / MemTotal) > 0.90` | [→](RUNBOOK.md#node-high-memory) |

### Two rules worth reading closely

#### Predictive disk exhaustion

```promql
predict_linear(
  kubelet_volume_stats_available_bytes{namespace="ivolve", persistentvolumeclaim=~"data-mysql-.*"}[6h],
  4 * 24 * 3600
) < 0
```

*"Extrapolating the last 6 hours of growth, will free space hit zero within 4 days?"*

A static "85% full" threshold is **useless if it took two years to get there and catastrophic if it took two hours**. `predict_linear` alerts on the trajectory, giving days of lead time — enough to expand the volume during business hours rather than at 3am.

#### CPU throttling

```promql
sum by (namespace, pod, container) (rate(container_cpu_cfs_throttled_periods_total[5m]))
  / sum by (namespace, pod, container) (rate(container_cpu_cfs_periods_total[5m])) > 0.25
```

> ⚠️ **A throttled container shows LOW CPU usage.** The kernel stops it for the remainder of each 100ms period, so the usage graph looks healthy while users experience latency. Without this specific alert, the symptom is routinely misdiagnosed as a network or database problem.

### Why `IvolveDeploymentReplicasMismatch` uses `for: 15m`

A rolling update *legitimately* creates this condition for a minute or two on **every single deploy**. A shorter window would page on every successful release — and an alert that fires on success is an alert people mute.

---

<a id="alert-design-principles"></a>

## 🎯 Alert Design Principles

### 1 · Every alert has a `for:`

```text
   Without `for:`                       With `for: 5m`
┌──────────────────────────────┐   ┌────────────────────────────────────┐
│ one failed scrape during a   │   │ condition must hold CONTINUOUSLY   │
│ rolling update → page at 03:00│   │ → transient blips ignored          │
│ → nothing was wrong           │   │ → real outages still fire          │
│ → people mute the alerts      │   │                                    │
└──────────────────────────────┘   └────────────────────────────────────┘
```

### 2 · Every alert has a `runbook_url`

An alert nobody knows how to action is noise. Each annotation links into [RUNBOOK.md](RUNBOOK.md).

### 3 · Alert on symptoms, not causes

| ✅ Symptom (users care) | ❌ Cause (may be harmless) |
|---|---|
| Service returning errors | CPU at 80% |
| Response time > 2s | Memory at 70% |
| Pod crash-looping | A pod restarted once |

Cause-based alerts are kept, but at `warning` severity — they are diagnostic context, not pages.

### 4 · Group and inhibit

```yaml
route:
  group_by: ["alertname", "namespace"]
  group_wait: 30s          # one notification listing 20 pods, not 20 pages

inhibit_rules:
  - source_matchers: [severity = "critical"]
    target_matchers: [severity = "warning"]
    equal: ["alertname", "namespace"]
```

When a node dies, the pod alerts it causes are **symptoms of one incident**, not twenty incidents.

### 5 · Critical alerts bypass the delay

```yaml
routes:
  - matchers: [severity = "critical"]
    receiver: "critical"
    group_wait: 10s
    repeat_interval: 1h
```

---

<a id="useful-promql"></a>

## 📐 Useful PromQL

```promql
# ── Availability ──────────────────────────────────────────────
probe_success{service=~"frontend|auth-service|roadmap-service"}

# 24-hour availability percentage — directly reportable as an SLO
avg_over_time(probe_success{service="frontend"}[24h]) * 100

# ── Latency ───────────────────────────────────────────────────
probe_duration_seconds
max_over_time(probe_duration_seconds{service="frontend"}[1h])

# ── Workloads ─────────────────────────────────────────────────
kube_pod_status_phase{namespace="ivolve", phase!="Running"} > 0
rate(kube_pod_container_status_restarts_total{namespace="ivolve"}[15m]) * 900

# Deployments not fully available
kube_deployment_spec_replicas{namespace="ivolve"}
  - kube_deployment_status_replicas_available{namespace="ivolve"} > 0

# ── Resources ─────────────────────────────────────────────────
sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="ivolve", container!=""}[5m]))

# Memory as a fraction of the limit — the OOM predictor
container_memory_working_set_bytes{namespace="ivolve", container!=""}
  / container_spec_memory_limit_bytes{namespace="ivolve", container!=""}

# Requests vs actual usage — finds over-provisioning
sum by (pod) (kube_pod_container_resource_requests{namespace="ivolve", resource="cpu"})
  - sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="ivolve"}[1h]))

# ── Storage ───────────────────────────────────────────────────
kubelet_volume_stats_used_bytes{namespace="ivolve"}
  / kubelet_volume_stats_capacity_bytes{namespace="ivolve"}

# ── Nodes ─────────────────────────────────────────────────────
1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m]))
1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)

# ── Meta: is monitoring itself healthy? ───────────────────────
up == 0
prometheus_tsdb_head_series                  # cardinality watch
rate(prometheus_target_scrapes_exceeded_sample_limit_total[5m]) > 0
```

> 💡 **`container_memory_working_set_bytes`, not `container_memory_usage_bytes`.** The latter includes reclaimable page cache and will look alarmingly high on a perfectly healthy container. Working set is what the kernel OOM-killer actually compares against the limit.

---

<a id="dashboards"></a>

## 📈 Dashboards

### Dashboards as code

```text
dashboards/ivolve-overview.json         ← source of truth, edit this
        │  make grafana-dashboard
        ▼
manifests/02-grafana-dashboard.yaml     ← GENERATED, do not edit
        │  labels: grafana_dashboard: "1"
        ▼
Grafana sidecar imports it (~60s, no restart)
```

A dashboard built by clicking around the Grafana UI lives only in Grafana's database — lost on reinstall, un-reviewable, and impossible to promote from dev to prod.

### Panels in `iVolve — Application Overview`

| Row | Panel | Answers |
|---|---|---|
| Availability | Service Up/Down | Is anything down right now? |
| | Response time | Is it getting slower? |
| Workload | Replicas desired vs available | Are pods failing to start? |
| | Container restarts (15m rate) | Is something crash-looping? |
| Resources | CPU usage | Where is the load? |
| | Memory working set | What is near OOM? |
| | **CPU throttling ratio** | **The invisible latency cause** |
| | PVC free space | Feeds the predictive disk alert |
| Nodes | Node CPU / memory | Is the cluster saturated? |

### Built-in dashboards worth knowing

kube-prometheus-stack ships excellent ones — do not rebuild them:

| Dashboard | Use |
|---|---|
| *Kubernetes / Compute Resources / Namespace (Pods)* | Per-pod resource breakdown |
| *Kubernetes / Compute Resources / Node (Pods)* | What is on each node |
| *Node Exporter / Nodes* | Deep host metrics |
| *Kubernetes / Persistent Volumes* | Storage capacity |
| *Alertmanager / Overview* | Alert flow |

---

<a id="retention-and-cost"></a>

## 💾 Retention and Cost

```yaml
retention: 15d
retentionSize: 8GB          # ← the safety net
storage: 20Gi
```

> ⚠️ **`retentionSize` matters more than `retention`.** Without it, Prometheus fills the PVC and crash-loops on a full disk — taking the monitoring system down at exactly the moment it is needed most.

> ⚠️ **Prometheus must have a PVC.** The chart default is `emptyDir`, so every restart discards all history. The first thing you do after an incident is then discover you have no data about it.

### Storage footprint

| Component | PVC | Monthly cost (gp3) |
|---|---:|---:|
| Prometheus | 20 Gi | ~$1.60 |
| Grafana | 5 Gi | ~$0.40 |
| Alertmanager | 2 Gi | ~$0.16 |

Negligible against the ~$231/month total — see the [cost estimate](../README.md#cost-estimate).

### Cardinality discipline

Prometheus memory scales with **series count**, not sample count. One high-cardinality label can multiply series by thousands.

```promql
prometheus_tsdb_head_series
topk(10, count by (__name__)({__name__=~".+"}))
```

**Never label a metric with:** a user ID, a request ID, a timestamp, a full URL with query parameters, or a raw error message.

`kube-state-metrics` is configured with an explicit allowlist rather than exporting every label:

```yaml
metricLabelsAllowlist:
  - pods=[app.kubernetes.io/name,app.kubernetes.io/component]
  - deployments=[app.kubernetes.io/name]
```

### EKS-specific exclusions

```yaml
kubeControllerManager: { enabled: false }
kubeScheduler:         { enabled: false }
kubeEtcd:              { enabled: false }
```

These components are AWS-managed and unreachable from inside the cluster. Leaving them enabled produces **four permanently-firing "target down" alerts on every EKS cluster** — noise that trains people to ignore alerts.

---

<a id="upgrade-path"></a>

## 🚀 Upgrade Path

### 1 · Add white-box metrics

Smallest change first — `roadmap-service`:

```xml
<dependency>
  <groupId>org.springframework.boot</groupId>
  <artifactId>spring-boot-starter-actuator</artifactId>
</dependency>
<dependency>
  <groupId>io.micrometer</groupId>
  <artifactId>micrometer-registry-prometheus</artifactId>
</dependency>
```

```properties
management.endpoints.web.exposure.include=health,prometheus
management.endpoint.health.probes.enabled=true
```

This yields `/actuator/prometheus` **plus** proper `/actuator/health/liveness` and `/readiness` endpoints, which would replace the current `/api/roadmap` probes with purpose-built ones.

Then:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: roadmap-service
  namespace: monitoring
spec:
  namespaceSelector: { matchNames: [ivolve] }
  selector:
    matchLabels: { app.kubernetes.io/name: roadmap-service }
  endpoints:
    - port: http
      path: /actuator/prometheus
      interval: 30s
```

Equivalents: `prom-client` (Express), `prometheus_flask_exporter` (Flask).

### 2 · Centralised logging

Only metrics are collected today. Add **Loki** for logs, correlated with metrics in the same Grafana:

```bash
helm install loki grafana/loki-stack -n monitoring \
  --set promtail.enabled=true --set grafana.enabled=false
```

### 3 · Distributed tracing

With three services in a request path, tracing shows *where* latency comes from:

```bash
helm install tempo grafana/tempo -n monitoring
```

Requires OpenTelemetry instrumentation in each service.

### 4 · SLOs and error budgets

```promql
# 30-day availability
avg_over_time(probe_success{service="frontend"}[30d]) * 100

# Error budget consumed against a 99.9% target
(1 - avg_over_time(probe_success{service="frontend"}[30d])) / 0.001
```

### 5 · Real notification channels

The `default` receiver is intentionally empty — alerts are visible in the UI but go nowhere. Wire up Slack, email or PagerDuty as shown in [Phase 7](../07-Monitoring/README.md#-wiring-up-notifications).

---

## ✅ Verify Monitoring Works

An untested alerting pipeline is an assumption, not a control.

```bash
# 1. One exporter per node
kubectl get daemonset -n monitoring
kubectl get nodes --no-headers | wc -l

# 2. All targets UP  → Prometheus → Status → Targets

# 3. 12 rules loaded → Prometheus → Alerts

# 4. Probes returning data
#    probe_success{service=~"frontend|auth-service|roadmap-service"}

# 5. Fire a real alert end to end
kubectl scale deploy/frontend -n ivolve --replicas=0
#    → IvolveServiceDown: Inactive → Pending → Firing (~2 min)
#    → appears in Alertmanager
kubectl scale deploy/frontend -n ivolve --replicas=2

# 6. Dashboard shows live data → Grafana → iVolve — Application Overview
```

> 💡 Step 5 with ArgoCD `selfHeal` enabled is a nice double demonstration: ArgoCD restores the replica count within 3 minutes, so you watch both the alert fire *and* the GitOps loop correct the drift.

---

**See also:** [Phase 7 setup](../07-Monitoring/README.md) · [RUNBOOK](RUNBOOK.md) · [ARCHITECTURE](ARCHITECTURE.md#failure-modes)
