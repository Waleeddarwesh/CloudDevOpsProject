# 🔁 CI/CD Pipeline

How code becomes a running container, and where the boundary between CI and CD sits.

For setup instructions see [Phase 5](../05-Jenkins/README.md). This document covers the design, the shared-library API, and the operational detail.

---

## 📑 Contents

- [The Full Path](#the-full-path)
- [Separation of Concerns](#separation-of-concerns)
- [Shared Library API](#shared-library-api)
- [Stage Reference](#stage-reference)
- [Gates](#gates)
- [Tagging Strategy](#tagging-strategy)
- [Jenkins Configuration](#jenkins-configuration)
- [Extending the Pipeline](#extending-the-pipeline)

---

<a id="the-full-path"></a>

## 🛤️ The Full Path

```text
 developer
     │ git push (application code)
     ▼
┌─────────────────── GitHub Actions ────────────────────┐
│ validates INFRASTRUCTURE code only — no AWS creds     │
│ terraform fmt/validate/tflint · checkov               │
│ kubeconform · hadolint · ansible-lint · gitleaks      │
└───────────────────────────────────────────────────────┘
     │
     ▼
┌─────────────────────── Jenkins ───────────────────────┐
│ 1 Checkout        tag = <build>-<git-sha>             │
│ 2 Unit Tests      containerised, per language         │
│ 3 SonarQube       + quality gate                      │
│ 4 Build Image     multi-stage, OCI provenance labels  │
│ 5 Scan Image      Trivy  ⛔ CRITICAL+fixable = FAIL    │
│ 6 Push Image      → ECR (instance profile)            │
│ 7 Delete Local    reclaim disk                        │
│ 8 Update Manifest kustomize edit set image            │
│ 9 Push Manifest   git commit [skip ci]                │
└───────────────────────────────────────────────────────┘
     │  Git now holds the desired state
     ▼
┌─────────────────────── ArgoCD ────────────────────────┐
│ detect → diff → apply by sync wave → self-heal        │
└───────────────────────────────────────────────────────┘
     │
     ▼
   EKS cluster
```

---

<a id="separation-of-concerns"></a>

## 🧭 Separation of Concerns

Three systems, three jobs, deliberately not merged.

| System | Validates / does | Needs AWS? | Needs cluster? |
|---|---|:---:|:---:|
| **GitHub Actions** | Infrastructure *code* — Terraform, manifests, Dockerfiles, playbooks | ❌ | ❌ |
| **Jenkins** | Application *images* — build, test, scan, publish | ✅ ECR only | ❌ |
| **ArgoCD** | Cluster *state* — reconcile from Git | ❌ | ✅ (runs inside) |

> 💡 **Jenkins holds no deployment credentials.** Its EKS access is `EDIT` on one namespace, used only for optional rollout verification. It cannot deploy — it commits, and ArgoCD deploys. A compromised Jenkins can push an image and open a commit, both of which leave an audit trail; it cannot silently change the cluster.

### Why GitHub Actions is separate

Fast feedback. A malformed manifest or an unformatted `.tf` file is caught in ~90 seconds on a pull request, before a reviewer spends time on it and long before anything reaches a cluster. It needs no AWS credentials, so it is safe to run on untrusted PRs.

---

<a id="shared-library-api"></a>

## 📚 Shared Library API

### `microservicePipeline(Map config)`

The only step a Jenkinsfile calls.

| Parameter | Required | Default | Notes |
|---|:---:|---|---|
| `serviceName` | ✅ | — | ECR repository **and** Kustomize image key — must match both |
| `sourceDir` | ✅ | — | Docker build context, e.g. `src/frontend` |
| `language` | ✅ | — | `node` \| `python` \| `java` |
| `ecrRegistry` | ✅ | — | `<account>.dkr.ecr.<region>.amazonaws.com` |
| `gitRepo` | ✅ | — | `github.com/User/Repo.git` — **no scheme** |
| `awsRegion` | | `us-east-1` | |
| `gitBranch` | | `main` | |
| `manifestDir` | | `04-Kubernetes/manifests` | Must contain `kustomization.yaml` |
| `runSonar` | | `true` | |
| `failOnCritical` | | `true` | The security gate |

Missing required parameters fail **before** the pipeline starts:

```groovy
List missing = required.findAll { !config.containsKey(it) || !config[it] }
if (missing) error("microservicePipeline: missing required parameter(s): ${missing.join(', ')}")
```

One clear message beats a `NullPointerException` fifteen minutes into a build.

### Individual steps

| Step | Signature | Returns |
|---|---|---|
| `runUnitTests` | `(language, sourceDir)` | — |
| `sonarQubeScan` | `(projectKey, sourceDir, language, version)` | — |
| `dockerBuildImage` | `(image, context, commit, buildNumber)` | image ref |
| `trivyScan` | `(image, failOnCritical, reportPrefix)` | JSON counts |
| `ecrPush` | `(image, registry, region)` | image digest |
| `updateManifests` | `(manifestDir, imageName, newImage, gitRepo, gitBranch, …)` | — |

Each is independently usable, so a custom pipeline can compose them differently.

---

<a id="stage-reference"></a>

## 🔍 Stage Reference

### 1 · Checkout

Derives the immutable tag and sets the build display name:

```groovy
env.IMAGE_TAG  = "${env.BUILD_NUMBER}-${scmVars.GIT_COMMIT.take(7)}"
env.FULL_IMAGE = "${env.ECR_REGISTRY}/${env.SERVICE_NAME}:${env.IMAGE_TAG}"
currentBuild.displayName = "#${BUILD_NUMBER} · ${SERVICE_NAME} · ${GIT_COMMIT_SHORT}"
```

`skipDefaultCheckout(true)` in options, then an explicit `checkout scm` — so `cleanWs()` can run first.

### 2 · Unit Tests

Runs **inside the same base image the Dockerfile uses**, not on the agent.

| Language | Command | Notes |
|---|---|---|
| `node` | `npm test` if `scripts.test` exists, plus `node --check server.js` | |
| `python` | `pytest` if tests exist, plus `python -m py_compile app.py` | |
| `java` | `mvn -B test` | `~/.m2` persisted via a Docker volume |

> 💡 The upstream application ships **no tests**. This step runs them when present and reports clearly when absent — it never silently passes a *failing* test, and never blocks over a *missing* one.

### 3 · SonarQube

Two distinct steps that are frequently conflated:

```text
① analysis  → scanner uploads results, exits immediately (async)
② gate      → waitForQualityGate() waits for the server's verdict
```

Running only ① produces a pipeline that reports "SonarQube: success" for code that fails every rule.

Java uses `sonar-maven-plugin` (reads module structure and coverage from the POM); Node and Python use the standalone scanner.

### 4 · Build Image

Injects OCI provenance labels at build time rather than in the Dockerfile — they change every build and would invalidate the layer cache:

```bash
--label org.opencontainers.image.revision='<full-sha>'
--label org.opencontainers.image.created='<ISO8601>'
--label io.jenkins.build-url='<build-url>'
```

Given only a running container, `docker inspect` then answers *"which commit is this?"*.

### 5 · Scan Image — see [Gates](#gates)

### 6 · Push Image

```bash
aws ecr get-login-password --region $REGION |
  docker login --username AWS --password-stdin $REGISTRY
```

Piped via `--password-stdin`, never `--password <token>` — the latter puts the secret in the process argument list, readable by `ps aux`.

Wrapped in `retry(3)`: a Docker push is idempotent (layers are skipped by digest), so retrying a transient network failure is safe. The digest is then verified via `aws ecr describe-images`.

### 7 · Delete Image Locally

Three services × 200-600 MB × 20 retained builds exhausts a 50 GB volume in days. The image is safely in ECR by this point.

### 8-9 · Update & Push Manifests

See [ARCHITECTURE § Design Decisions](ARCHITECTURE.md#design-decisions) for the `sed` vs Kustomize analysis.

Rebase-and-retry handles the race when two pipelines finish close together:

```bash
git pull --rebase origin main || true
git push https://${GIT_USERNAME}:${GIT_TOKEN}@$REPO HEAD:main
```

> ⚠️ Note the **single-quoted** shell block — the token is expanded by the shell from an environment variable, not interpolated by Groovy. Groovy interpolation would write the secret into the script file on disk and echo it into the console log.

---

<a id="gates"></a>

## ⛔ Gates

| Gate | Blocks? | Threshold | Rationale |
|---|:---:|---|---|
| Unit tests | ✅ | Any failing test | |
| SonarQube | ⚠️ `unstable` | Project quality gate | Upstream has pre-existing findings; documented baseline |
| **Trivy** | ✅ **FAILS BUILD** | CRITICAL **with a fix available** | The primary security control |
| Gitleaks (Actions) | ✅ | Any secret in history | |
| Checkov (Actions) | ⚠️ soft-fail | Terraform misconfig | Opinionated defaults flag deliberate choices |

### The Trivy gate in detail

```text
Pass 1 ── --exit-code 0 ── always succeeds ── writes table + JSON reports
Pass 2 ── --exit-code 1 ── fails on CRITICAL+fixable
```

Two invocations because a single failing run aborts the shell **before** the report is written — leaving nothing to diagnose. Reports are archived as build artefacts.

```bash
--scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --timeout 10m
```

| Flag | Why |
|---|---|
| `--ignore-unfixed` | Without it, every build fails on unpatchable base-image CVEs. A gate everyone bypasses is worse than none. |
| `--severity CRITICAL` (pass 2) | HIGH is reported, CRITICAL blocks. A calibrated threshold. |
| shared `--cache-dir` | The ~600 MB vulnerability DB is pre-warmed by the Ansible `trivy` role and refreshed nightly by cron. |

**Verify the gate is real** — pin an old base image and confirm the build fails and nothing reaches ECR. Instructions in [Phase 5 § step 9](../05-Jenkins/README.md).

### Bypassing — deliberately, with a record

```groovy
failOnCritical: false   // a documented risk acceptance, visible in Git
```

The pipeline then logs `⚠️ Security gate is DISABLED for this service`.

---

<a id="tagging-strategy"></a>

## 🏷️ Tagging Strategy

```text
991216470475.dkr.ecr.us-east-1.amazonaws.com/ivolve-frontend:42-a1b2c3d
└──────────── registry ────────────────────┘ └── repo ────┘ └── tag ─┘
                                                            │    │
                                              Jenkins build ┘    └ git sha
```

| Scheme | Verdict |
|---|---|
| `latest` | ❌ Moving target. Rollback is meaningless, and you cannot say what is running. |
| `${BUILD_NUMBER}` | ⚠️ Tells you *when*, not *what*. |
| **`42-a1b2c3d`** | ✅ Maps a running container to an exact commit. |

Paired with `image_tag_mutability = "IMMUTABLE"` in ECR: a tag that can be overwritten makes the audit trail a fiction. With immutability, `ivolve-frontend:42-a1b2c3d` means today exactly what it meant when it passed the Trivy gate.

The ECR lifecycle policy keeps the last 10 tagged images and expires untagged ones after 1 day.

---

<a id="jenkins-configuration"></a>

## 🔧 Jenkins Configuration

### Pipeline options and why each is there

```groovy
buildDiscarder(logRotator(numToKeepStr: '20', artifactNumToKeepStr: '10'))
timeout(time: 45, unit: 'MINUTES')
disableConcurrentBuilds()
timestamps()
ansiColor('xterm')
skipDefaultCheckout(true)
```

| Option | Prevents |
|---|---|
| `buildDiscarder` | Unbounded history filling `JENKINS_HOME` — the most common cause of a Jenkins controller that "suddenly broke" |
| `timeout` | A hung `docker pull` occupying an executor forever |
| `disableConcurrentBuilds` | Two runs racing on the shared Docker daemon **and** both pushing a manifest commit → non-fast-forward rejection |
| `timestamps` | Guessing which stage was slow |
| `skipDefaultCheckout` | Checking out before `cleanWs()` can run |

### Credentials

| ID | Kind | Scope |
|---|---|---|
| `github-token` | Username with password | Fine-grained PAT, **one repository**, `Contents: Read and write` |
| `sonar-token` | Secret text | SonarQube user token |

**No AWS credential exists.** The instance profile supplies temporary, auto-rotating credentials — see [SECURITY § Identity](SECURITY.md#identity-and-access).

### RBAC *(internship Lab 21)*

`role-strategy` and `matrix-auth` are provisioned by the Ansible `jenkins` role.

| Role | Scope | Permissions |
|---|---|---|
| `admin` | global | Overall/Administer |
| `developer` | global | Overall/Read, Job/Read, Job/Build, Job/Cancel |
| `viewer` | global | Overall/Read, Job/Read |
| `frontend-team` | project `ivolve-frontend.*` | Job/Read, Job/Build, Job/Workspace |

### Agents *(internship Lab 23)*

The pipeline uses `agent any`, which runs on the built-in node — fine for this scale. For a real controller:

```groovy
agent { label 'docker && linux' }
```

Then add agents via *Manage Jenkins → Nodes*, or use the Kubernetes plugin for ephemeral pod agents:

```groovy
agent {
    kubernetes {
        yaml '''
            spec:
              containers:
                - name: docker
                  image: docker:27-dind
                  securityContext: { privileged: true }
        '''
    }
}
```

> 💡 Running builds on the controller is convenient but couples build load to controller stability. Separate agents are the first thing to add as the team grows.

---

<a id="extending-the-pipeline"></a>

## 🧩 Extending the Pipeline

### Add a stage

Add a step in `vars/`, then wire it into `microservicePipeline.groovy`:

```groovy
stage('Integration Tests') {
    when { expression { return config.runIntegrationTests } }
    steps {
        script {
            integrationTests(sourceDir: env.SOURCE_DIR, image: env.FULL_IMAGE)
        }
    }
}
```

All three services inherit it immediately — that is the point of the library.

### Add a fourth service

```groovy
@Library('shared-library') _

microservicePipeline(
    serviceName: 'ivolve-notification-service',
    sourceDir:   'src/notification-service',
    language:    'python',
    ecrRegistry: '991216470475.dkr.ecr.us-east-1.amazonaws.com',
    gitRepo:     'github.com/WaleedDarwesh/CloudDevOpsProject.git'
)
```

Then add the ECR repository to `ecr_repository_names` in `terraform.tfvars` and an entry to the `images:` block in `kustomization.yaml`.

### Add SBOM generation

```groovy
sh "trivy image --format cyclonedx --output sbom.json ${env.FULL_IMAGE}"
archiveArtifacts artifacts: 'sbom.json'
```

### Add image signing

```groovy
sh """
    cosign sign --key env://COSIGN_KEY ${env.FULL_IMAGE}
    cosign verify --key env://COSIGN_PUB ${env.FULL_IMAGE}
"""
```

Then enforce signatures at admission with a Kyverno or Sigstore policy.

### Notifications

```groovy
post {
    failure {
        slackSend(
            color: 'danger',
            message: "❌ ${env.SERVICE_NAME} #${env.BUILD_NUMBER} failed at '${env.STAGE_NAME}'\n${env.BUILD_URL}"
        )
    }
}
```

---

## 📈 Typical Timings

| Stage | frontend | auth-service | roadmap-service |
|---|---:|---:|---:|
| Checkout | 5s | 5s | 5s |
| Unit Tests | 25s | 40s | 90s |
| SonarQube | 45s | 40s | 70s |
| Build Image | 60s | 90s | 150s |
| Scan Image | 30s | 40s | 45s |
| Push Image | 40s | 50s | 70s |
| Update/Push Manifests | 15s | 15s | 15s |
| **Total** | **~3.5 min** | **~4.5 min** | **~7.5 min** |

`roadmap-service` is slowest — a Maven build plus a JVM image. The `~/.m2` Docker volume roughly halves repeat builds.

---

**See also:** [Phase 5 setup](../05-Jenkins/README.md) · [ARCHITECTURE](ARCHITECTURE.md) · [SECURITY](SECURITY.md) · [TROUBLESHOOTING](TROUBLESHOOTING.md#jenkins)
