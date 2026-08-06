# 📊 Phase 7: Monitoring & Observability

## 📌 Overview

A deployment you cannot observe is a deployment you cannot operate. This phase adds the **kube-prometheus-stack** — Prometheus, Grafana, Alertmanager, node-exporter and kube-state-metrics — plus **black-box HTTP probes**, **12 alert rules** with runbook links, and a **version-controlled Grafana dashboard**.

This is the internship's [Lab 19 (DaemonSets)](../README.md#-internship-labs-applied) and [Lab 20+ (full monitoring stack with RBAC)](../README.md#-internship-labs-applied) applied to a real application.

---

# 📖 Understanding the Stack

One Helm chart installs six components that answer different questions.

```text
                    ┌──────────────────────────────────┐
                    │          Prometheus              │
                    │  scrape · store · evaluate rules │
                    └───┬──────────┬─────────┬─────────┘
          scrapes       │          │         │
        ┌───────────────┘          │         └────────────┐
        ▼                          ▼                      ▼
┌──────────────────┐  ┌────────────────────┐  ┌────────────────────┐
│  node-exporter   │  │ kube-state-metrics │  │ blackbox-exporter  │
│  (DaemonSet)     │  │   (Deployment)     │  │   (Deployment)     │
│                  │  │                    │  │                    │
│ "this NODE is at │  │ "this DEPLOYMENT   │  │ "GET / returned    │
│  90% memory"     │  │  wants 3, has 1"   │  │  200 in 42ms"      │
│  INFRASTRUCTURE  │  │  ORCHESTRATION     │  │  USER EXPERIENCE   │
└──────────────────┘  └────────────────────┘  └────────────────────┘

        Prometheus ──► Alertmanager ──► (Slack / email / PagerDuty)
        Prometheus ──► Grafana       ──► dashboards
```

> 💡 **You need all three sources.** A node can be perfectly healthy while every pod on it is `CrashLoopBackOff`; a Deployment can report 3/3 Ready while the application returns 500 to every request.

### node-exporter is a DaemonSet — and that matters

```text
   DaemonSet (correct)                 Deployment replicas: 2 (wrong)
┌──────────────────────────────┐   ┌────────────────────────────────┐
│ node-1 ──► exporter pod      │   │ node-1 ──► exporter pod × 2     │
│ node-2 ──► exporter pod      │   │ node-2 ──► (none)               │
│ node-3 ──► exporter pod      │   │                                 │
│  (added by the autoscaler)   │   │ ✗ both landed on one node       │
│ ✓ exactly one per node,      │   │ ✗ node-2 is unmonitored, and    │
│   automatically              │   │   nothing tells you             │
└──────────────────────────────┘   └────────────────────────────────┘
```

> ⚠️ `tolerations: [{operator: Exists}]` is required. Without it, a **tainted** node — such as one dedicated to the database via `workload=database:NoSchedule` — silently gets no exporter, and its metrics simply vanish with no error anywhere.

---

# 📖 Understanding White-box vs Black-box Monitoring

**This is the key design decision in this phase.**

None of the three microservices expose Prometheus metrics. The upstream application has no `/metrics` endpoint anywhere:

| Service | Why not |
|---|---|
| `frontend` | Express, no `prom-client` |
| `auth-service` | Flask, no `prometheus_flask_exporter` |
| `roadmap-service` | Spring Boot **without** `spring-boot-starter-actuator` |

A `ServiceMonitor` would have nothing to scrape.

```text
   White-box                            Black-box (used here)
┌──────────────────────────────┐   ┌────────────────────────────────────┐
│ App exposes /metrics         │   │ Prober makes REAL HTTP requests    │
│                              │   │                                    │
│ request rate, latency        │   │ probe_success{service="frontend"}=1│
│ histograms, GC stats,        │   │ probe_duration_seconds = 0.042     │
│ business counters            │   │ probe_http_status_code = 200       │
│                              │   │                                    │
│ ✓ deep internal insight      │   │ ✓ NO application change required   │
│ ✗ requires changing the app  │   │ ✓ measures what a USER experiences │
│                              │   │ ✗ no internal detail               │
└──────────────────────────────┘   └────────────────────────────────────┘
```

Black-box was chosen because it works against the application **exactly as shipped**, keeping `src/` byte-identical to upstream and independently verifiable. It also answers the more direct question: *can a user actually log in?*

The two are complementary. The white-box upgrade path is one dependency and two properties — see [Adding white-box metrics](#-adding-white-box-metrics-optional).

> 💡 The probes target **cluster-internal** URLs rather than the public ALB address. That isolates application health from load-balancer health: if the internal probe passes but users report errors, the problem is the ALB or DNS, not the app.

---

# 📖 Understanding Alert Design

Every rule here has a `for:` duration. That single field is what separates an **alert** from **noise**.

```text
   Without `for:`                       With `for: 5m`
┌──────────────────────────────┐   ┌────────────────────────────────────┐
│ one failed scrape during a   │   │ condition must hold CONTINUOUSLY   │
│ rolling update               │   │ for 5 minutes                      │
│   → page at 03:00            │   │   → transient blips ignored        │
│   → nothing was wrong        │   │   → real outages still fire        │
│   → people mute the alerts   │   │                                    │
└──────────────────────────────┘   └────────────────────────────────────┘
```

### The 12 rules

| Group | Alert | Severity | `for:` | Fires when |
|---|---|:---:|:---:|---|
| **availability** | `IvolveServiceDown` | 🔴 critical | 2m | An HTTP probe fails |
| | `IvolveServiceSlow` | 🟡 warning | 5m | Response time > 2s |
| **workloads** | `IvolvePodCrashLooping` | 🔴 critical | 5m | > 3 restarts in 15m |
| | `IvolveDeploymentReplicasMismatch` | 🟡 warning | 15m | Desired ≠ available |
| | `IvolvePodNotReady` | 🟡 warning | 10m | Pod Pending/Unknown |
| **database** | `IvolveMySQLDown` | 🔴 critical | 2m | StatefulSet has 0 ready |
| | `IvolveDatabaseVolumeFillingUp` | 🟡 warning | 1h | **Predicted** full within 4 days |
| **resources** | `IvolveContainerCPUThrottling` | 🟡 warning | 10m | Throttled > 25% of periods |
| | `IvolveContainerMemoryNearLimit` | 🟡 warning | 10m | > 90% of the limit |
| **nodes** | `IvolveNodeNotReady` | 🔴 critical | 5m | Node NotReady |
| | `IvolveNodeDiskPressure` | 🟡 warning | 5m | Kubelet reports DiskPressure |
| | `IvolveNodeHighMemory` | 🟡 warning | 10m | Node memory > 90% |

### Two rules worth reading closely

**Predictive disk alerting** — a static "85% full" threshold is useless if it took two years to get there and catastrophic if it took two hours:

```promql
predict_linear(kubelet_volume_stats_available_bytes{…}[6h], 4*24*3600) < 0
```
*"Based on the last 6 hours of growth, will this volume hit zero within 4 days?"*

**CPU throttling** — a genuinely invisible failure mode:

```promql
rate(container_cpu_cfs_throttled_periods_total[5m])
  / rate(container_cpu_cfs_periods_total[5m]) > 0.25
```

> ⚠️ A throttled container shows **LOW** CPU usage on a normal graph, precisely because the kernel is stopping it. Users experience latency with no visible cause. This is why it needs its own alert and its own dashboard panel.

### `IvolveDeploymentReplicasMismatch` has `for: 15m` on purpose

A rolling update *legitimately* creates this condition for a minute or two on **every single deploy**. A shorter window would page on every successful release.

### Alertmanager grouping and inhibition

```yaml
route:
  group_by: ["alertname", "namespace"]   # one notification, 20 pods listed
  group_wait: 30s

inhibit_rules:
  - source_matchers: [severity = "critical"]
    target_matchers: [severity = "warning"]
    equal: ["alertname", "namespace"]
```

When a node dies, the pod alerts it causes are **symptoms, not separate incidents**. Inhibition suppresses them.

---

# 📖 Understanding Dashboards as Code

```text
   Built in the Grafana UI              ConfigMap + sidecar (used here)
┌──────────────────────────────┐   ┌────────────────────────────────────┐
│ lives in Grafana's database  │   │ dashboards/ivolve-overview.json    │
│ ✗ lost on reinstall          │   │   ↓ generated into                 │
│ ✗ cannot be code-reviewed    │   │ manifests/02-grafana-dashboard.yaml│
│ ✗ cannot be promoted dev→prod│   │   labels: grafana_dashboard: "1"   │
│ ✗ no history                 │   │   ↓ sidecar auto-imports (~60s)    │
└──────────────────────────────┘   │ ✓ versioned, reviewable, portable  │
                                   └────────────────────────────────────┘
```

The Grafana sidecar watches for ConfigMaps carrying `grafana_dashboard: "1"` and imports them automatically — no restart needed.

---

## 🎯 Objectives

- Deploy Prometheus, Grafana, Alertmanager, node-exporter and kube-state-metrics.
- Monitor the application **without modifying its source**, using black-box probes.
- Define meaningful alert rules with tuned `for:` durations and runbook links.
- Version-control the Grafana dashboard as a ConfigMap.
- Persist metrics so history survives a restart.

---

## 📂 Project Structure

```text
07-Monitoring/
├── kube-prometheus-stack-values.yaml   # Helm values for the whole stack
├── manifests/
│   ├── 01-blackbox-probes.yaml         # Probe CR + PrometheusRule (12 alerts)
│   └── 02-grafana-dashboard.yaml       # GENERATED — do not edit directly
├── dashboards/
│   └── ivolve-overview.json            # dashboard source of truth
└── README.md
```

---

## 🛠 Technologies Used

- kube-prometheus-stack (Helm)
- Prometheus + Prometheus Operator (`ServiceMonitor`, `Probe`, `PrometheusRule` CRDs)
- Grafana · Alertmanager
- node-exporter (DaemonSet) · kube-state-metrics · blackbox-exporter
- PromQL

---

## ✅ Prerequisites

- [Phase 4](../04-Kubernetes/) deployed — the application is running.
- Helm 3 installed.
- A working `StorageClass` — Prometheus and Grafana both need PVCs.

---

# 📋 Steps

## 1. Install the stack

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
kubectl create namespace monitoring

helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values kube-prometheus-stack-values.yaml \
  --wait --timeout 15m
```

Or: `make mon-install`

⏱ **Expect 5–10 minutes** — several images and CRD registration.

> ⚠️ **Change `grafana.adminPassword` first.** The chart default is `admin/prom-operator`, which is public knowledge.

---

## 2. Install the blackbox exporter

```bash
helm install blackbox-exporter \
  prometheus-community/prometheus-blackbox-exporter \
  --namespace monitoring
```

---

## 3. Apply the probes, alerts and dashboard

```bash
kubectl apply -f manifests/
```

---

## 4. Verify

```bash
kubectl get pods -n monitoring
```
```text
NAME                                              READY   STATUS
alertmanager-monitoring-kube-prometheus-…-0       2/2     Running
blackbox-exporter-prometheus-blackbox-…-x2k4p     1/1     Running
monitoring-grafana-7d5f9c8b4-m3n8q                3/3     Running
monitoring-kube-prometheus-operator-…-p2m4q       1/1     Running
monitoring-kube-state-metrics-…-hj3n2             1/1     Running
monitoring-prometheus-node-exporter-4kd8x         1/1     Running   ← node 1
monitoring-prometheus-node-exporter-9wm2p         1/1     Running   ← node 2
prometheus-monitoring-kube-prometheus-…-0         2/2     Running
```

Confirm the DaemonSet placed **exactly one exporter per node**:

```bash
kubectl get daemonset -n monitoring
kubectl get nodes --no-headers | wc -l
```

---

## 5. Explore Prometheus

```bash
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090
```

Open **<http://localhost:9090>**.

**Status → Targets** — everything should be `UP`. Then try these queries:

```promql
# Are the three services responding?
probe_success{service=~"frontend|auth-service|roadmap-service"}

# Response times
probe_duration_seconds

# Pods not Running
kube_pod_status_phase{namespace="ivolve", phase!="Running"} > 0

# CPU per pod
sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="ivolve"}[5m]))

# Memory as a fraction of the limit
container_memory_working_set_bytes{namespace="ivolve", container!=""}
  / container_spec_memory_limit_bytes{namespace="ivolve", container!=""}
```

**Alerts** tab — all 12 rules should be loaded and `Inactive`.

> 🔧 **No `probe_success` results?** The `Probe` CR was not discovered. Confirm `probeSelectorNilUsesHelmValues: false` in the values file — the chart default restricts discovery to objects labelled `release=monitoring`, which silently ignores hand-written CRs.

---

## 6. Explore Grafana

```bash
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80
```

Open **<http://localhost:3000>** (`admin` / your password).

**Dashboards → iVolve — Application Overview** — the imported dashboard, with panels for:

| Row | Panels |
|---|---|
| Service Availability | Up/Down stat · response time |
| Workload Health | desired vs available replicas · restart rate |
| Resource Usage | CPU vs limit · memory working set · **throttling ratio** · PVC free space |
| Nodes | CPU utilisation · memory utilisation |

The chart also ships excellent built-in dashboards — try **Kubernetes / Compute Resources / Namespace (Pods)**.

---

## 7. Test an alert end to end

Prove the pipeline works rather than assuming it:

```bash
# Scale the frontend to zero — probes will start failing
kubectl scale deploy/frontend -n ivolve --replicas=0
```

After ~2 minutes, `IvolveServiceDown` moves `Inactive → Pending → Firing` in the Prometheus **Alerts** tab, then appears in Alertmanager:

```bash
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-alertmanager 9093:9093
# → http://localhost:9093
```

Restore:

```bash
kubectl scale deploy/frontend -n ivolve --replicas=2
```

> ⚠️ With ArgoCD `selfHeal` enabled, it will restore the replica count for you within 3 minutes — which is a nice demonstration of two systems working correctly at once.

---

## 8. Editing the dashboard

Edit the **JSON source**, not the ConfigMap:

```bash
# 1. edit dashboards/ivolve-overview.json
# 2. regenerate the ConfigMap
make grafana-dashboard
# 3. re-apply
kubectl apply -f manifests/02-grafana-dashboard.yaml
```

The sidecar picks it up within ~60 seconds.

---

## 🔔 Wiring up notifications

The `default` receiver is intentionally empty — alerts are visible in the Alertmanager UI but go nowhere. To add Slack:

```bash
kubectl create secret generic alertmanager-slack -n monitoring \
  --from-literal=url='https://hooks.slack.com/services/T00/B00/XXXX'
```

Then in `kube-prometheus-stack-values.yaml`:

```yaml
receivers:
  - name: "critical"
    slack_configs:
      - api_url_file: /etc/alertmanager/secrets/alertmanager-slack/url
        channel: "#ivolve-alerts"
        title: '{{ .CommonLabels.alertname }}'
        text: '{{ range .Alerts }}{{ .Annotations.description }}{{ end }}'
```

```bash
helm upgrade monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring -f kube-prometheus-stack-values.yaml
```

---

## 🔬 Adding white-box metrics (optional)

To get true application metrics, the smallest change is `roadmap-service`:

```xml
<!-- src/roadmap-service/pom.xml -->
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
# src/roadmap-service/src/main/resources/application.properties
management.endpoints.web.exposure.include=health,prometheus
management.endpoint.health.probes.enabled=true
```

That yields `/actuator/prometheus` plus proper `/actuator/health/liveness` and `/readiness` endpoints, which would replace the current probes. Then add a `ServiceMonitor`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: roadmap-service
  namespace: monitoring
spec:
  namespaceSelector:
    matchNames: [ivolve]
  selector:
    matchLabels:
      app.kubernetes.io/name: roadmap-service
  endpoints:
    - port: http
      path: /actuator/prometheus
      interval: 30s
```

Equivalents: `prom-client` for Express, `prometheus_flask_exporter` for Flask.

> 💡 **This is deliberately not applied.** Keeping `src/` byte-identical to upstream means the vendored source can be verified against the original commit. The path is documented so the trade-off is a choice, not an omission.

---

## 🔧 Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `ServiceMonitor`/`Probe` never scraped | Chart's default label selector | Set `*SelectorNilUsesHelmValues: false` (already done) |
| Prometheus pod `Pending` | No PVC could bind | Check the `StorageClass` and `kubectl describe pvc -n monitoring` |
| Prometheus OOM-killed | Retention too high for the memory limit | Lower `retention`/`retentionSize` or raise the limit |
| Four permanently-firing "target down" alerts | EKS control plane is AWS-managed | Already disabled via `kubeScheduler/kubeControllerManager/kubeEtcd: false` |
| Grafana shows "No data" | Wrong datasource, or Prometheus has no data yet | Check **Status → Targets** in Prometheus first |
| Dashboard not imported | Label missing | The ConfigMap needs `grafana_dashboard: "1"` |
| `probe_success` absent | blackbox-exporter not installed, or wrong service name | `kubectl get svc -n monitoring \| grep blackbox` |
| Alerts fire but no notification | No receiver configured | See [Wiring up notifications](#-wiring-up-notifications) |

---

# 📸 Screenshots

| Description | Image |
|---|---|
| All monitoring pods Running | `Screenshots/monitoring_pods.png` |
| node-exporter DaemonSet — one pod per node | `Screenshots/node_exporter_daemonset.png` |
| Prometheus Targets all UP | `Screenshots/prometheus_targets.png` |
| `probe_success` query results | `Screenshots/prometheus_probes.png` |
| 12 alert rules loaded | `Screenshots/prometheus_alerts.png` |
| Grafana — iVolve Application Overview | `Screenshots/grafana_overview.png` |
| Grafana — resource usage row | `Screenshots/grafana_resources.png` |
| `IvolveServiceDown` firing | `Screenshots/alert_firing.png` |
| Alertmanager UI | `Screenshots/alertmanager.png` |

---

## 📚 Key Learning Outcomes

- Deploy a complete observability stack and explain what each component contributes.
- Distinguish node-exporter (infrastructure), kube-state-metrics (orchestration) and blackbox-exporter (user experience).
- Explain why node-exporter is a DaemonSet and why it must tolerate all taints.
- Choose between white-box and black-box monitoring, and justify the trade-off.
- Write PromQL for rates, ratios and **predictive** thresholds.
- Tune `for:` durations so alerts are actionable rather than noisy.
- Use Alertmanager grouping and inhibition to suppress symptom alerts.
- Manage dashboards as code through the ConfigMap sidecar.
- Recognise CPU throttling as a failure mode invisible on a usage graph.

---

## 💡 Best Practices

- **Always give Prometheus a PVC.** The chart default is `emptyDir`, so every restart discards all history — and the first thing you do after an incident is discover you have no data about it.
- Set `retentionSize` as well as `retention`; otherwise Prometheus fills the disk and crash-loops exactly when it is most needed.
- Every alert needs a `for:` duration and a `runbook_url`. An alert nobody knows how to action is noise.
- Alert on **symptoms** (service down, high latency) rather than causes (CPU high) — users care about symptoms.
- Use `externalLabels` (`cluster`, `environment`) so a second cluster's metrics are distinguishable.
- Disable EKS control-plane scrape targets — four permanently-firing alerts train people to ignore alerts.
- Store dashboards as ConfigMaps so they survive a reinstall and can be reviewed.
- Use `metricLabelsAllowlist` on kube-state-metrics to expose the pod labels your queries filter on.
- Cap cardinality: never label a metric with a user ID, request ID or timestamp.
- Test that alerts actually fire — an untested alerting pipeline is an assumption, not a control.

---

## 🌍 Real-World Use Cases

- **SLO tracking** — `probe_success` over 30 days is a directly reportable availability figure.
- **Capacity planning** — `predict_linear` on disk and memory forecasts exhaustion before it happens.
- **Incident response** — a `runbook_url` in every annotation turns a page into a procedure.
- **Cost optimisation** — actual usage vs requests reveals over-provisioning.
- **Autoscaling validation** — confirm the HPA reacts before the user-facing latency does.
- **Post-incident review** — 15 days of retained history to reconstruct what happened.
- **Compliance** — evidence that monitoring and alerting controls exist and function.

---

## 🧹 Cleanup

```bash
kubectl delete -f manifests/
helm uninstall blackbox-exporter -n monitoring
helm uninstall monitoring -n monitoring

# PVCs are NOT removed by helm uninstall
kubectl delete pvc --all -n monitoring
kubectl delete namespace monitoring

# The Prometheus Operator CRDs are also left behind
kubectl delete crd -l app.kubernetes.io/part-of=kube-prometheus-stack
```

---

## ✅ Result

A complete observability stack running alongside the application: **Prometheus** with 15-day persistent retention, **Grafana** with a version-controlled dashboard imported automatically by the sidecar, **Alertmanager** with severity-based routing and symptom inhibition, **node-exporter** as a DaemonSet tolerating all taints, **kube-state-metrics**, and **black-box HTTP probes** that monitor all three microservices **without a single change to the application source**.

**12 alert rules** cover availability, workload health, database capacity, resource saturation and node health — each with a tuned `for:` window and a runbook link, including a predictive disk-exhaustion alert and a CPU-throttling alert for a failure mode that is otherwise invisible.

**Validated:** the dashboard ConfigMap parses as YAML and its embedded dashboard parses as JSON ✅

**Back to:** [Project README →](../README.md)
