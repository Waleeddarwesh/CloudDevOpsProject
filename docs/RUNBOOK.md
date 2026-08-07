# 📕 Incident Runbook

Procedures for the alerts defined in [`07-Monitoring/manifests/01-blackbox-probes.yaml`](../07-Monitoring/manifests/01-blackbox-probes.yaml). Each alert's `runbook_url` annotation links directly to the matching section here.

**An alert without a runbook is noise.** This file is what turns a page into a procedure.

---

## 📑 Alert Index

| Alert | Severity | Section |
|---|:---:|---|
| `IvolveServiceDown` | 🔴 | [Service Down](#service-down) |
| `IvolveServiceSlow` | 🟡 | [Service Slow](#service-slow) |
| `IvolvePodCrashLooping` | 🔴 | [CrashLoopBackOff](#crashloopbackoff) |
| `IvolveDeploymentReplicasMismatch` | 🟡 | [Replicas Mismatch](#replicas-mismatch) |
| `IvolvePodNotReady` | 🟡 | [Pod Pending](#pod-pending) |
| `IvolveMySQLDown` | 🔴 | [MySQL Down](#mysql-down) |
| `IvolveDatabaseVolumeFillingUp` | 🟡 | [Disk Filling Up](#disk-filling-up) |
| `IvolveContainerCPUThrottling` | 🟡 | [CPU Throttling](#cpu-throttling) |
| `IvolveContainerMemoryNearLimit` | 🟡 | [Memory Near Limit](#memory-near-limit) |
| `IvolveNodeNotReady` | 🔴 | [Node NotReady](#node-notready) |
| `IvolveNodeDiskPressure` | 🟡 | [Node Disk Pressure](#node-disk-pressure) |
| `IvolveNodeHighMemory` | 🟡 | [Node High Memory](#node-high-memory) |

---

## 🔧 First Response — always start here

```bash
# Orientation, in one command
kubectl get pods,svc,ingress,hpa -n ivolve
kubectl get events -n ivolve --sort-by='.lastTimestamp' | tail -25
```

`events` is the single most useful command in Kubernetes triage and the one people skip.

```bash
# Is the failure user-visible?
ALB=$(kubectl get ingress frontend -n ivolve -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -sS -o /dev/null -w "%{http_code} in %{time_total}s\n" "http://$ALB/"
```

| Result | Meaning |
|---|---|
| `200` | Users are fine — the alert may be a false positive or partial |
| `503` | ALB has no healthy targets |
| `502` | Targets exist but are erroring |
| timeout | ALB or DNS problem, not the application |

---

<a id="service-down"></a>

## 🔴 Service Down

> `IvolveServiceDown` — HTTP probes have failed for 2 minutes.

### Diagnose

```bash
SVC=frontend   # or auth-service / roadmap-service

kubectl get pods -n ivolve -l app.kubernetes.io/name=$SVC
kubectl describe deploy/$SVC -n ivolve | tail -20
kubectl logs -n ivolve -l app.kubernetes.io/name=$SVC --tail=100

# Is the Service actually selecting any pods?
kubectl get endpoints $SVC -n ivolve
```

> 💡 **`ENDPOINTS <none>` is the key signal.** It means either no pods match the selector, or none are passing readiness. The Service itself is fine.

### Resolve by cause

| Cause | Check | Fix |
|---|---|---|
| No pods running | `kubectl get pods` | → [CrashLoopBackOff](#crashloopbackoff) / [Pod Pending](#pod-pending) |
| Pods running, not Ready | `kubectl describe pod` → Conditions | Readiness probe failing — check its dependency |
| Endpoints empty | `kubectl get endpoints` | Label selector mismatch between Deployment and Service |
| Bad image just deployed | `kubectl rollout history` | **Roll back** (below) |
| Dependency down | `auth-service` needs MySQL | → [MySQL Down](#mysql-down) |

### Roll back

```bash
# GitOps-native — preferred, keeps Git authoritative
git revert <bad-commit> && git push
# ArgoCD syncs within ~3 min, or force it:
kubectl patch application ivolve-app -n argocd --type merge -p '{"operation":{"sync":{}}}'
```

```bash
# Emergency only — ArgoCD selfHeal will revert this within 3 minutes
kubectl rollout undo deploy/$SVC -n ivolve
```

> ⚠️ An emergency `kubectl` fix **must be followed by a Git commit**, or `selfHeal` undoes your fix.

### Blast radius

| Service down | Impact |
|---|---|
| `frontend` | 🔴 Total outage |
| `auth-service` | 🟡 Login/signup fail; existing sessions and the roadmap page still work |
| `roadmap-service` | 🟡 Roadmap page errors; login still works |

---

<a id="service-slow"></a>

## 🟡 Service Slow

> `IvolveServiceSlow` — response time above 2s for 5 minutes.

```bash
kubectl top pods -n ivolve
kubectl get hpa -n ivolve
```

| Cause | Signal | Fix |
|---|---|---|
| **CPU throttling** | Grafana throttling panel > 25% | → [CPU Throttling](#cpu-throttling) |
| Under-scaled | HPA at `maxReplicas` | Raise `maxReplicas` in the manifest |
| Slow queries | MySQL slow log | `kubectl logs mysql-0 -n ivolve \| grep -i "slow"` |
| JVM GC pressure | roadmap-service only | Raise the memory limit; `MaxRAMPercentage` scales with it |
| Node saturation | `kubectl top nodes` | Scale the node group |

> 💡 Check throttling **first**. It is the most common cause and the least visible — a throttled container shows *low* CPU precisely because the kernel is stopping it.

---

<a id="crashloopbackoff"></a>

## 🔴 CrashLoopBackOff

> `IvolvePodCrashLooping` — more than 3 restarts in 15 minutes.

### The one command that matters

```bash
kubectl logs -n ivolve <pod> --previous
```

**`--previous`** shows the logs of the container that *died*. Without it you see the current, still-starting container — which is why people report "the logs are empty".

```bash
kubectl describe pod -n ivolve <pod> | grep -A15 "Last State"
```

### Decode the exit code

| Exit code | Meaning | Action |
|:---:|---|---|
| `0` | Container exited cleanly | Wrong CMD, or the process is not long-running |
| `1` | Application error | Read `--previous` logs |
| **`137`** | **SIGKILL — OOM-killed** | → [Memory Near Limit](#memory-near-limit) |
| `139` | SIGSEGV | Application bug |
| `143` | SIGTERM | Normal shutdown; probably a probe killed it |

### Known causes in this stack

| Symptom | Cause | Fix |
|---|---|---|
| `Missing database environment variables: DB_USER` | ConfigMap key wrong | `app.py` reads **`DB_USER`**, not `DB_USERNAME` |
| `Access denied for user 'ivolve_user'` | `MYSQL_PASSWORD` ≠ `DB_PASSWORD` | They are the same credential — make them match |
| `Unable to create tempDir` | `readOnlyRootFilesystem` with no `/tmp` | Ensure the `tmp` `emptyDir` volume is mounted |
| Exit 137 on roadmap-service | JVM heap > container limit | Confirm `JAVA_OPTS` includes `-XX:MaxRAMPercentage=75.0` |
| Restart every ~30s, no error | gunicorn heartbeat can't write `/tmp` | Mount the `tmp` volume |
| `Data directory has files in it` | MySQL on a volume root containing `lost+found` | `subPath: mysql` must be set on the mount |

### Stop the loop to investigate

```bash
kubectl scale deploy/<name> -n ivolve --replicas=0
# … investigate …
kubectl scale deploy/<name> -n ivolve --replicas=2
```

---

<a id="pod-pending"></a>

## 🟡 Pod Pending

> `IvolvePodNotReady` — Pending or Unknown for 10 minutes.

```bash
kubectl describe pod -n ivolve <pod> | tail -20     # read the Events
```

| Event message | Cause | Fix |
|---|---|---|
| `Insufficient cpu` / `Insufficient memory` | No node has room | Scale the node group, or lower requests |
| `pod has unbound immediate PersistentVolumeClaims` | PVC not binding | See below |
| `exceeded quota` | ResourceQuota hit | `kubectl describe resourcequota -n ivolve` |
| `node(s) had untolerated taint` | Taint without a matching toleration | Add the toleration, or remove the taint |
| `volume node affinity conflict` | **EBS volume in the wrong AZ** | StorageClass must use `WaitForFirstConsumer` |

### PVC not binding

```bash
kubectl get pvc -n ivolve
kubectl describe pvc data-mysql-0 -n ivolve
kubectl get storageclass
kubectl get pods -n kube-system -l app=ebs-csi-controller
```

**Most likely causes, in order:**

1. **EBS CSI driver missing.** It stopped shipping with EKS in 1.23.
   ```bash
   aws eks describe-addon --cluster-name ivolve-dev-eks --addon-name aws-ebs-csi-driver
   ```
2. **Wrong provisioner.** Must be `ebs.csi.aws.com`, never `kubernetes.io/aws-ebs` (removed in 1.27).
3. **IRSA role missing.** The driver is running but cannot call `CreateVolume`:
   ```bash
   kubectl logs -n kube-system -l app=ebs-csi-controller -c ebs-plugin --tail=50
   ```

---

<a id="mysql-down"></a>

## 🔴 MySQL Down

> `IvolveMySQLDown` — the StatefulSet has 0 ready replicas.

**Impact:** login and signup fail. The roadmap page still works (stateless).

> 💡 The auth-service pods **stay UP** — deliberately. Their liveness probe is `tcpSocket`, not `/health`, so a database outage does not trigger a restart storm. They leave the Service endpoints via readiness and rejoin automatically when MySQL returns.

### Diagnose

```bash
kubectl get statefulset,pods,pvc -n ivolve -l app.kubernetes.io/name=mysql
kubectl logs mysql-0 -n ivolve --tail=100
kubectl describe pod mysql-0 -n ivolve | tail -25
```

| Log line | Cause | Fix |
|---|---|---|
| `Permission denied` on the data dir | `fsGroup` not applied | Confirm `fsGroup: 999` in the pod securityContext |
| `Data directory has files in it` | `lost+found` on a fresh volume | `subPath: mysql` on the volumeMount |
| `Table 'mysql.user' doesn't exist` | Corrupted data directory | Restore from snapshot |
| `Out of memory` / exit 137 | Buffer pool > container limit | `innodb_buffer_pool_size` must stay well below the memory limit |
| Pod Pending | PVC or scheduling | → [Pod Pending](#pod-pending) |

### Recovery

```bash
# 1. Restart the pod — the PVC re-attaches, data is preserved
kubectl delete pod mysql-0 -n ivolve
kubectl get pods -n ivolve -w

# 2. Verify once Running
kubectl exec -it mysql-0 -n ivolve -- \
  mysql -u root -p"$(kubectl get secret ivolve-secret -n ivolve \
    -o jsonpath='{.data.MYSQL_ROOT_PASSWORD}' | base64 -d)" \
  -e "SELECT COUNT(*) FROM ivolve.users;"

# 3. Recover auth-service
kubectl rollout restart deploy/auth-service -n ivolve
```

### If the volume is corrupted

```bash
# The volume SURVIVES pod deletion (reclaimPolicy: Retain)
kubectl get pv
aws ec2 describe-snapshots --owner-ids self \
  --filters "Name=tag:kubernetes.io/created-for/pvc/name,Values=data-mysql-0"
```

> ⚠️ **Automated snapshots are not configured** — see [ARCHITECTURE.md § Known Limitations](ARCHITECTURE.md#known-limitations). Without a snapshot, corruption means data loss. This is the highest-priority production gap.

---

<a id="disk-filling-up"></a>

## 🟡 Disk Filling Up

> `IvolveDatabaseVolumeFillingUp` — `predict_linear` forecasts exhaustion within 4 days.

This is **predictive** — you have days, not minutes.

```bash
kubectl exec mysql-0 -n ivolve -- df -h /var/lib/mysql
```

### Expand the volume (online, no downtime)

`allowVolumeExpansion: true` is already set.

```bash
kubectl patch pvc data-mysql-0 -n ivolve \
  -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'

kubectl get pvc data-mysql-0 -n ivolve -w
kubectl exec mysql-0 -n ivolve -- df -h /var/lib/mysql
```

> ⚠️ EBS volumes can **only grow**. There is no shrink path.
> ⚠️ AWS enforces a ~6-hour cooldown between modifications of the same volume.

### Reclaim space instead

```bash
# Find the largest tables
kubectl exec mysql-0 -n ivolve -- mysql -u root -p"$PW" -e "
SELECT table_name, ROUND((data_length+index_length)/1024/1024,2) AS mb
FROM information_schema.tables WHERE table_schema='ivolve'
ORDER BY mb DESC;"

# Binary logs are often the culprit
kubectl exec mysql-0 -n ivolve -- mysql -u root -p"$PW" \
  -e "PURGE BINARY LOGS BEFORE DATE(NOW() - INTERVAL 7 DAY);"
```

---

<a id="cpu-throttling"></a>

## 🟡 CPU Throttling

> `IvolveContainerCPUThrottling` — throttled in >25% of scheduling periods.

**This is the most commonly misdiagnosed problem in Kubernetes.**

```text
   What the CPU graph shows            What is actually happening
┌──────────────────────────────┐   ┌────────────────────────────────────┐
│ CPU usage: 38% — looks fine  │   │ The container hits its limit,      │
│                              │   │ the kernel STOPS it for the rest   │
│ "must be a network problem"  │   │ of each 100ms period.              │
│                              │   │ Low usage IS the symptom.          │
└──────────────────────────────┘   └────────────────────────────────────┘
```

```bash
kubectl top pod -n ivolve
```

```promql
# In Prometheus — the real signal
sum by (pod) (rate(container_cpu_cfs_throttled_periods_total{namespace="ivolve"}[5m]))
  / sum by (pod) (rate(container_cpu_cfs_periods_total{namespace="ivolve"}[5m]))
```

### Fix — raise the limit

Edit the manifest, commit, let ArgoCD deploy:

```yaml
resources:
  requests: { cpu: 100m }
  limits:   { cpu: 800m }    # was 400m
```

> ⚠️ The **LimitRange** caps `maxLimitRequestRatio` at 10 for CPU. Raising the limit beyond 10× the request is rejected at admission — raise the request too.

> 💡 If throttling is chronic, the request is wrong. Set the request to the observed p95 usage; that is what the scheduler reserves.

---

<a id="memory-near-limit"></a>

## 🟡 Memory Near Limit

> `IvolveContainerMemoryNearLimit` — above 90% of the limit.

Unlike CPU, exceeding a memory limit is **not** throttled — the kernel **kills** the container (exit 137).

```bash
kubectl top pod -n ivolve
kubectl describe pod -n ivolve <pod> | grep -A3 "Last State"
```

| Service | Common cause | Fix |
|---|---|---|
| `roadmap-service` | JVM heap sized from the host, not the cgroup | Verify `-XX:MaxRAMPercentage=75.0` is in `JAVA_OPTS` |
| `auth-service` | gunicorn workers × connection pool | Reduce `--workers`, or raise the limit |
| `frontend` | Session objects accumulating in `MemoryStore` | The real fix is a Redis session store |
| `mysql` | `innodb_buffer_pool_size` too close to the limit | Keep it well below; mysqld needs headroom |

```yaml
resources:
  requests: { memory: 256Mi }
  limits:   { memory: 1Gi }     # was 512Mi
```

> ⚠️ The LimitRange caps `maxLimitRequestRatio` at **4** for memory. `256Mi → 1Gi` is exactly 4×; going higher requires raising the request.

---

<a id="node-notready"></a>

## 🔴 Node NotReady

> `IvolveNodeNotReady` — with only 2 nodes, this is **half the cluster**.

```bash
kubectl get nodes
kubectl describe node <node> | grep -A10 Conditions
kubectl get pods -A -o wide --field-selector spec.nodeName=<node>
```

| Condition | Meaning | Action |
|---|---|---|
| `MemoryPressure=True` | Node is out of memory | Kubelet is evicting; find the greedy pod |
| `DiskPressure=True` | Disk full | → [Node Disk Pressure](#node-disk-pressure) |
| `NetworkUnavailable=True` | CNI failure | Check `aws-node` pods |
| `Unknown` | Kubelet not reporting | Instance may be dead |

### Recover

```bash
# 1. Stop new scheduling
kubectl cordon <node>

# 2. Move the pods off. PDBs (minAvailable: 1) prevent a full outage.
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --timeout=300s

# 3. Let the managed node group replace it
aws ec2 terminate-instances --instance-ids <id>
kubectl get nodes -w        # a replacement joins in ~5 min
```

> ⚠️ If `drain` stalls, a PodDisruptionBudget is doing its job. Check `kubectl get pdb -n ivolve` — draining would breach `minAvailable`. Scale up first, then drain.

> ⚠️ `mysql-0` on the failed node means **downtime until it reschedules and the EBS volume re-attaches** (2-5 min). This is the documented single point of failure.

---

<a id="node-disk-pressure"></a>

## 🟡 Node Disk Pressure

```bash
kubectl describe node <node> | grep -A5 "Allocated resources"
kubectl debug node/<node> -it --image=busybox -- df -h /host
```

Almost always accumulated container images.

```bash
# Force image garbage collection by cordoning briefly, or clean directly:
kubectl debug node/<node> -it --image=busybox -- \
  chroot /host crictl rmi --prune
```

> 💡 The Ansible `jenkins` role installs a nightly `docker system prune` cron on the **build server**. Worker nodes rely on the kubelet's own image GC, which triggers at 85% disk usage.

---

<a id="node-high-memory"></a>

## 🟡 Node High Memory

```bash
kubectl top nodes
kubectl top pods -A --sort-by=memory | head -15
```

```promql
1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)
```

**Options, in order of preference:**

1. Scale the node group — `node_max_size` is 4.
2. Reduce requests if they are over-provisioned relative to real usage.
3. Move a workload to a different node with `nodeSelector`.

> 💡 Eviction order under pressure is **BestEffort → Burstable → Guaranteed**. MySQL is Guaranteed (requests == limits), so it is evicted last — deliberately, since it holds the only persistent state.

---

## 📞 Escalation

| Severity | Response | Action |
|---|---|---|
| 🔴 Critical | Immediate | Follow the runbook; roll back if a recent deploy is implicated |
| 🟡 Warning | Next business day | Investigate and tune |
| 🟢 Info | Best effort | Track as a backlog item |

### Golden commands

```bash
# Everything, at once
kubectl get all,ingress,pvc,hpa,pdb -n ivolve

# What just happened
kubectl get events -A --sort-by='.lastTimestamp' | tail -30

# Why did it die
kubectl logs -n ivolve <pod> --previous

# What is ArgoCD doing
kubectl get application ivolve-app -n argocd -o yaml | grep -A20 status:

# Is it the network
kubectl exec -n ivolve deploy/frontend -- wget -qO- --timeout=3 http://auth-service:5000/health
```

---

**See also:** [TROUBLESHOOTING](TROUBLESHOOTING.md) (setup problems) · [MONITORING](MONITORING.md) (alert definitions) · [ARCHITECTURE](ARCHITECTURE.md#failure-modes) (failure modes)
