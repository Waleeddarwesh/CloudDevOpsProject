# ⚙️ Phase 5: Continuous Integration with Jenkins

## 📌 Overview

This phase delivers a **Groovy Shared Library** that defines one 9-stage pipeline, consumed by three microservices. Each `Jenkinsfile` is ~15 lines of configuration; **all** the logic lives in `vars/`.

The pipeline builds an image, gates it on a real Trivy security scan and a SonarQube quality gate, pushes to ECR, and then hands off to GitOps by committing an updated image tag — it never deploys directly.

---

# 📖 Understanding Shared Libraries

Without a shared library, every service copies the same pipeline. Three copies drift, and a fix has to be applied three times.

```text
   Without a shared library              With a shared library
┌──────────────────────────────┐   ┌────────────────────────────────────┐
│ frontend/Jenkinsfile         │   │ frontend.Jenkinsfile      15 lines │
│   180 lines                  │   │ auth-service.Jenkinsfile  15 lines │
│ auth/Jenkinsfile             │   │ roadmap.Jenkinsfile       15 lines │
│   180 lines (copy-pasted)    │   │              │                     │
│ roadmap/Jenkinsfile          │   │              ▼                     │
│   180 lines (already drifted)│   │ vars/microservicePipeline.groovy   │
│                              │   │ vars/dockerBuildImage.groovy       │
│ fix a bug → edit 3 files     │   │ vars/trivyScan.groovy              │
│ 540 lines to review          │   │ vars/ecrPush.groovy                │
└──────────────────────────────┘   │ vars/updateManifests.groovy        │
└──────────────────────────────┘   │ vars/pushManifests.groovy          │
                                   │ vars/runUnitTests.groovy           │
                                   │ vars/sonarQubeScan.groovy          │
                                   │                                    │
                                   │ fix a bug → edit 1 file            │
                                   └────────────────────────────────────┘
```

### Required repository layout

A Jenkins Global Shared Library expects a **specific structure at the repository root**:

```text
<library-repo-root>/
├── vars/          ← global steps, callable by filename
│   └── myStep.groovy   → invoked as  myStep(...)
├── src/           ← optional Groovy classes (com/ivolve/...)
└── resources/     ← optional static files
```

> ⚠️ **This is the one constraint that catches everyone.** `vars/` must be at the **repository root**. In this project the library lives at `05-Jenkins/vars/`, which Jenkins **cannot** consume directly. See [Setting up the library](#3-set-up-the-shared-library) for the two supported ways to resolve this.

### The `_` in the import

```groovy
@Library('shared-library') _
```

The trailing underscore is **required** — it is not a typo. The `@Library` annotation must attach to a statement, and `_` is the conventional no-op. Omitting it produces `unable to resolve class` errors that give no hint about the real cause.

---

# 📖 Understanding the Pipeline

```text
 ┌─ 1 Checkout ──────────── derive IMAGE_TAG = <build>-<git-sha>
 ├─ 2 Unit Tests ────────── containerised, language-aware
 ├─ 3 SonarQube ────────── analysis + BLOCKING quality gate
 ├─ 4 Build Image ───────── docker build + OCI provenance labels
 ├─ 5 Scan Image ────────── Trivy — CRITICAL+fixable ⇒ BUILD FAILS ⛔
 ├─ 6 Push Image ────────── → ECR (instance profile, no static keys)
 ├─ 7 Delete Image ──────── reclaim local disk
 ├─ 8 Update Manifests ──── kustomize edit set image
 └─ 9 Push Manifests ────── git commit [skip ci] → ArgoCD takes over
```

Stages 4–9 are the six required by the brief. Stages 1–3 are what make it a real pipeline rather than a build script.

### Why the image tag is not `latest`

```groovy
env.IMAGE_TAG = "${env.BUILD_NUMBER}-${env.GIT_COMMIT_SHORT}"   // → 42-a1b2c3d
```

| Tag scheme | Problem |
|---|---|
| `latest` | Moving target — you cannot say what is running, and rollback is meaningless |
| `${BUILD_NUMBER}` | Tells you *when*, not *what* |
| **`42-a1b2c3d`** | ✅ Maps a running container back to an exact commit |

This also pairs with **`IMMUTABLE` ECR tags** (set in Terraform): a tag that can be overwritten makes the whole audit trail a fiction.

---

# 📖 Understanding the Security Gate

Trivy runs at stage 5 — **before the push at stage 6**. That ordering is the entire point: scanning *after* pushing means the vulnerable image is already in the registry and pullable.

```text
   ❌ Scan after push                  ✅ Scan before push (used here)
┌──────────────────────────┐      ┌──────────────────────────────────┐
│ build → push → scan      │      │ build → scan → push              │
│                          │      │           │                      │
│ vulnerable image is      │      │           └─ CRITICAL+fixable    │
│ already in ECR and       │      │              ⇒ FAIL, never pushed│
│ pullable by anything     │      │                                  │
└──────────────────────────┘      └──────────────────────────────────┘
```

### Why two Trivy invocations

```groovy
// Pass 1 — --exit-code 0 : always succeeds, writes the reports
// Pass 2 — --exit-code 1 : fails the build on a fixable CRITICAL
```

A single failing invocation aborts the shell before the report file is written — leaving nothing to look at when diagnosing *why* the build was blocked.

### Why `--ignore-unfixed`

Without it, every build fails on CVEs in the base image for which **no patched package exists yet**. There is no action a developer can take, so the gate becomes noise — and **a gate everyone routes around is worse than no gate at all**. With it, the gate fires only on vulnerabilities that rebuilding can actually fix.

---

# 📖 Understanding the GitOps Handoff

Stages 8 and 9 are where CI ends and CD begins. **Jenkins never runs `kubectl apply`.**

```text
   Jenkins                              ArgoCD
┌────────────────────────┐         ┌──────────────────────────┐
│ kustomize edit set     │         │ watches the repo         │
│   image ivolve-frontend│         │                          │
│   =…/ivolve-frontend:42│ ──git──►│ detects the new revision │
│                        │  commit │ syncs the cluster        │
│ git commit [skip ci]   │         │ prune + selfHeal         │
│ git push               │         └──────────────────────────┘
└────────────────────────┘
   Git is now the source of truth for what is deployed
```

### Why `kustomize edit set image` and not `sed`

The naive approach:

```bash
sed -i 's|image: .*|image: NEW_IMAGE|g' 05-auth-service.yaml   # ⛔ DANGEROUS
```

That regex matches **every** line starting with `image:`. In this repository it would also rewrite:

- `busybox:1.36` — the init container in `05-auth-service.yaml`
- `mysql:8.0` — the database in `04-database.yaml`

silently replacing the database with an application image. The failure appears at deploy time as an inexplicable CrashLoopBackOff.

**Proof that Kustomize gets it right** — from the actual rendered output of this repository:

```text
image: 991216470475.dkr.ecr…/ivolve-auth-service:dev     ← rewritten ✅
image: busybox:1.36                                       ← untouched ✅
image: 991216470475.dkr.ecr…/ivolve-frontend:dev          ← rewritten ✅
image: 991216470475.dkr.ecr…/ivolve-roadmap-service:dev   ← rewritten ✅
image: mysql:8.0                                          ← untouched ✅
```

### Why `[skip ci]` is essential

Without it, each build pushes a commit that triggers another build — an **infinite loop** that runs until someone notices the executor is permanently busy.

---

# 📖 Understanding Credential Handling

There are **no AWS credentials anywhere in this pipeline**. The Jenkins EC2 instance carries an IAM instance profile ([Phase 2](../02-Terraform/modules/server/main.tf)), so the AWS CLI obtains temporary, auto-rotating credentials from the metadata service.

```text
   ❌ Static access key              ✅ Instance profile (used here)
┌───────────────────────────┐   ┌────────────────────────────────────┐
│ Jenkins credential:       │   │ EC2 instance profile               │
│   AKIA...                 │   │   → temporary creds, auto-rotated  │
│                           │   │   → scoped to 3 ECR repos          │
│ never rotates             │   │   → IMDSv2 required (SSRF-proof)   │
│ readable via script       │   │   → nothing on disk to steal       │
│   console                 │   │                                    │
│ THE way CI compromise     │   │                                    │
│ becomes account compromise│   │                                    │
└───────────────────────────┘   └────────────────────────────────────┘
```

The one credential that *is* required is the GitHub token for the manifest push. Note how it is interpolated:

```groovy
sh '''
    git push https://${GIT_USERNAME}:${GIT_TOKEN}@''' + gitRepo + ''' HEAD:main
'''
```

**Single quotes**, so the *shell* expands the variable from the environment. Using Groovy interpolation (`"${GIT_TOKEN}"`) would embed the secret into the script Jenkins writes to disk and echoes into the console log.

---

## 🎯 Objectives

- Deliver a Jenkins pipeline for each microservice.
- Implement the six required stages: **Build Image, Scan Image, Push Image, Delete Image Locally, Update Manifests, Push Manifests**.
- Use a **Shared Library** so all three pipelines share one definition.
- *Beyond the brief:* unit tests, SonarQube quality gate, immutable tagging, Kustomize-based updates, workspace hygiene and Jenkins RBAC.

---

## 📂 Project Structure

```text
05-Jenkins/
├── Jenkinsfiles/
│   ├── frontend.Jenkinsfile          # language: node
│   ├── auth-service.Jenkinsfile      # language: python
│   └── roadmap-service.Jenkinsfile   # language: java
│
└── vars/                             # ← the shared library
    ├── microservicePipeline.groovy   # orchestrator — the 9 stages
    ├── runUnitTests.groovy           # language-aware, containerised
    ├── sonarQubeScan.groovy          # analysis + waitForQualityGate
    ├── dockerBuildImage.groovy       # build + OCI provenance labels
    ├── trivyScan.groovy              # the security gate
    ├── ecrPush.groovy                # login, push, verify digest
    └── updateManifests.groovy        # kustomize image update (no Git)
    └── pushManifests.groovy          # git commit + push — CI→CD handoff
```

### Shared library API

| Step | Purpose |
|---|---|
| `microservicePipeline(Map)` | The complete pipeline. The only step a Jenkinsfile calls. |
| `runUnitTests(language, sourceDir)` | `npm test` / `pytest` / `mvn test`, each in its matching base image |
| `sonarQubeScan(projectKey, sourceDir, language, version)` | Scanner + **blocking** quality gate |
| `dockerBuildImage(image, context, commit, buildNumber)` | Build with `org.opencontainers.image.*` labels |
| `trivyScan(image, failOnCritical, reportPrefix)` | Two-pass scan; fails on fixable CRITICAL |
| `ecrPush(image, registry, region)` | ECR login → push (retry ×3) → verify digest → logout |
| `updateManifests(...)` | `kustomize edit set image` → commit → rebase-retry push |

### `microservicePipeline` parameters

| Parameter | Required | Default | Description |
|---|:---:|---|---|
| `serviceName` | ✅ | — | ECR repo **and** Kustomize image key |
| `sourceDir` | ✅ | — | Docker build context |
| `language` | ✅ | — | `node` \| `python` \| `java` |
| `ecrRegistry` | ✅ | — | `<account>.dkr.ecr.<region>.amazonaws.com` |
| `gitRepo` | ✅ | — | `github.com/User/Repo.git` (no scheme) |
| `awsRegion` | | `us-east-1` | |
| `gitBranch` | | `main` | |
| `manifestDir` | | `04-Kubernetes/manifests` | |
| `runSonar` | | `true` | |
| `failOnCritical` | | `true` | The security gate |

---

## 🛠 Technologies Used

- Jenkins LTS + Declarative Pipeline
- Groovy (Shared Library)
- Docker + BuildKit
- Trivy · SonarQube · Kustomize · AWS CLI v2 · Git
- Key plugins: `workflow-cps-global-lib`, `docker-workflow`, `sonar`, `credentials-binding`, `ws-cleanup`, `role-strategy`, `matrix-auth`

---

## ✅ Prerequisites

- [Phase 3](../03-Ansible/) complete — Jenkins running with all tools installed.
- A GitHub **fine-grained Personal Access Token** with `Contents: Read and write` on this repository only.
  > ⚠️ Do **not** use a classic token with full `repo` scope — it grants access to every repository you own.

---

# 📋 Steps

## 1. Complete the Jenkins setup wizard

```bash
ssh -i ~/.ssh/ivolve-key.pem ubuntu@<JENKINS_IP> \
  'sudo cat /var/lib/jenkins/secrets/initialAdminPassword'
```

Open `http://<JENKINS_IP>:8080`, unlock, and create your admin user. Plugins are already installed by the [Ansible jenkins role](../03-Ansible/roles/jenkins/) — choose **Select plugins to install → None**.

---

## 2. Add credentials

**Manage Jenkins → Credentials → System → Global credentials**

| ID | Kind | Value |
|---|---|---|
| `github-token` | Username with password | Your GitHub username + the PAT |
| `sonar-token` | Secret text | Generated in SonarQube: *My Account → Security → Generate Token* |

> 💡 The IDs are referenced by name in the shared library. They must match exactly.

---

## 3. Set up the shared library

Because Jenkins requires `vars/` at the **repository root**, choose one of:

### Option A — dedicated library repository *(recommended)*

```bash
# One-time setup
git clone https://github.com/Waleeddarwesh/jenkins-shared-library.git
cd jenkins-shared-library
cp -r ../CloudDevOpsProject/05-Jenkins/vars .
git add vars && git commit -m "feat: sync shared library" && git push
```

Keep it in sync with a small script:

```bash
#!/usr/bin/env bash
# scripts/sync-shared-library.sh
set -euo pipefail
LIB_REPO="${1:?usage: sync-shared-library.sh <path-to-library-repo>}"
rsync -av --delete 05-Jenkins/vars/ "$LIB_REPO/vars/"
cd "$LIB_REPO"
git add vars
git diff --cached --quiet && { echo "no changes"; exit 0; }
git commit -m "chore: sync shared library from CloudDevOpsProject"
git push
```

### Option B — same repository, non-root path

Jenkins can load a library from a subdirectory using the *Modern SCM* retriever with a **Library Path**. Fewer moving parts, but the library and application code then share a commit history, so a docs-only change bumps the library version.

### Configure it

**Manage Jenkins → System → Global Pipeline Libraries → Add**

| Field | Value |
|---|---|
| Name | `shared-library` |
| Default version | `main` |
| ☑ Load implicitly | leave **unchecked** |
| ☑ Allow default version to be overridden | checked |
| Retrieval method | *Modern SCM* → *Git* |
| Project Repository | your library repo URL |
| Credentials | `github-token` |

---

## 4. Configure SonarQube

**Manage Jenkins → System → SonarQube servers**

| Field | Value |
|---|---|
| Name | `sonarqube` ← must match `SONARQUBE_SERVER` in `sonarQubeScan.groovy` |
| Server URL | `http://localhost:9000` |
| Authentication token | `sonar-token` |

**Manage Jenkins → Tools → SonarQube Scanner installations**

| Field | Value |
|---|---|
| Name | `sonar-scanner` ← must match `SONARQUBE_SCANNER` |
| ☑ Install automatically | latest version |

> ⚠️ **Configure the SonarQube webhook**, or `waitForQualityGate()` polls until it times out:
> SonarQube → *Administration → Configuration → Webhooks → Create*
> URL: `http://<JENKINS_IP>:8080/sonarqube-webhook/`

---

## 5. Create the pipeline jobs

For each of the three services: **New Item → Pipeline**

| Field | Value |
|---|---|
| Name | `ivolve-frontend` |
| Definition | *Pipeline script from SCM* |
| SCM | Git → this repository |
| Credentials | `github-token` |
| Branch | `*/main` |
| **Script Path** | `05-Jenkins/Jenkinsfiles/frontend.Jenkinsfile` |

Repeat with `auth-service.Jenkinsfile` and `roadmap-service.Jenkinsfile`.

> 💡 Update `ecrRegistry` and `gitRepo` in each Jenkinsfile first:
> ```bash
> terraform -chdir=02-Terraform output -raw ecr_registry
> ```

---

## 6. Configure RBAC *(internship Lab 21)*

The `role-strategy` plugin is already installed.

**Manage Jenkins → Security → Authorization → Role-Based Strategy**, then **Manage and Assign Roles → Manage Roles**:

| Role | Pattern | Permissions |
|---|---|---|
| `admin` | global | Overall/Administer |
| `developer` | global | Overall/Read, Job/Read, Job/Build, Job/Cancel |
| `viewer` | global | Overall/Read, Job/Read |

Project roles restrict a team to their own services:

| Project role | Pattern | Permissions |
|---|---|---|
| `frontend-team` | `ivolve-frontend.*` | Job/Read, Job/Build, Job/Workspace |

---

## 7. Run a build

Click **Build Now** on `ivolve-frontend`.

```text
Started by user Waleed Darwesh
[Pipeline] stage (Checkout)
╔════════════════════════════════════════════════════════╗
  Service : ivolve-frontend
  Source  : src/frontend
  Commit  : a1b2c3d
  Image   : 991216470475.dkr.ecr.us-east-1.amazonaws.com/ivolve-frontend:42-a1b2c3d
╚════════════════════════════════════════════════════════╝

[Pipeline] stage (Unit Tests)
✅ server.js parses cleanly

[Pipeline] stage (SonarQube Analysis)
✅ SonarQube Quality Gate passed.

[Pipeline] stage (Build Image)
✅ Built …/ivolve-frontend:42-a1b2c3d (142M)

[Pipeline] stage (Scan Image)
───────────────────── Trivy report ─────────────────────
ivolve-frontend:42-a1b2c3d (alpine 3.21)
Total: 0 (HIGH: 0, CRITICAL: 0)
────────────────────────────────────────────────────────
Vulnerability counts (fixable only): {}
✅ Security gate passed — no fixable CRITICAL vulnerabilities.

[Pipeline] stage (Push Image)
✅ Pushed …/ivolve-frontend:42-a1b2c3d
   digest: sha256:9f2c...

[Pipeline] stage (Delete Image Locally)
Removing local image …

[Pipeline] stage (Update & Push Manifests)
── kustomization.yaml AFTER ──
  - name: ivolve-frontend
    newTag: 42-a1b2c3d
✅ kustomize build succeeds
✅ Manifests updated and pushed

✅ SUCCESS — ivolve-frontend
   ArgoCD will now sync the cluster to this revision.
Finished: SUCCESS
```

---

## 8. Verify the handoff

```bash
git pull
git log --oneline -1
```
```text
b3c4d5e ci(ivolve-frontend): deploy 991216470475.dkr.ecr…/ivolve-frontend:42-a1b2c3d
```

```bash
aws ecr describe-images --repository-name ivolve-frontend \
  --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageTags'
```

Then watch [ArgoCD](../06-ArgoCD/) pick it up.

---

## 9. Test that the gate actually blocks

Prove the security gate is real rather than decorative — temporarily pin an old base image:

```dockerfile
FROM node:18.0-alpine AS runtime    # known CRITICAL CVEs
```

Run the build:

```text
[Pipeline] stage (Scan Image)
Total: 7 (CRITICAL: 3)

❌ SECURITY GATE FAILED
ivolve-frontend:43-e5f6a7b contains CRITICAL vulnerabilities that have a fix available.
The image was NOT pushed to ECR.
Finished: FAILURE
```

Confirm nothing reached ECR, then revert.

---

## 🔧 Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `unable to resolve class` on `@Library` | Missing trailing `_` | `@Library('name') _` |
| `No such DSL method 'microservicePipeline'` | `vars/` is not at the library repo root | See [step 3](#3-set-up-the-shared-library) |
| `docker: permission denied` | jenkins not in the docker group | Re-run the Ansible jenkins role |
| `no basic auth credentials` on push | Instance profile not attached, or wrong region | `aws sts get-caller-identity` on the server |
| `waitForQualityGate` hangs | SonarQube webhook not configured | Add the webhook (step 4) |
| `non-fast-forward` on manifest push | Two pipelines raced | Handled by the rebase-retry; if persistent, check `disableConcurrentBuilds` |
| Build loops forever | `[skip ci]` missing or webhook ignores it | Confirm the commit message contains `[skip ci]` |
| `no space left on device` | Docker images accumulating | The Ansible role installs a nightly `docker system prune` cron |

---

# 📸 Screenshots

| Description | Image |
|---|---|
| Jenkins dashboard with three pipeline jobs | `Screenshots/jenkins_jobs.png` |
| Global Pipeline Library configuration | `Screenshots/shared_library_config.png` |
| Stage View across all 9 stages | `Screenshots/stage_view.png` |
| Trivy report in the console | `Screenshots/trivy_report.png` |
| **Build FAILED by the security gate** | `Screenshots/trivy_gate_fail.png` |
| SonarQube project dashboard | `Screenshots/sonarqube_project.png` |
| ECR showing the immutable pushed tag | `Screenshots/ecr_image.png` |
| The automated `ci(...)` commit in GitHub | `Screenshots/gitops_commit.png` |
| Role-Based Authorization matrix | `Screenshots/jenkins_rbac.png` |

---

## 📚 Key Learning Outcomes

- Build a Groovy Shared Library and understand the mandatory `vars/`-at-root layout.
- Compose a declarative pipeline from small, single-purpose reusable steps.
- Design an immutable tagging scheme that makes rollback and audit meaningful.
- Implement a security gate that genuinely blocks, and understand why `--ignore-unfixed` is what keeps it credible.
- Integrate SonarQube and understand why `waitForQualityGate()` — not just the scanner — is what makes it a gate.
- Hand off from CI to CD through Git rather than by deploying directly.
- Use Kustomize for image updates and explain the concrete danger of the `sed` approach.
- Handle secrets correctly: instance profiles over static keys, shell interpolation over Groovy interpolation.
- Configure Jenkins RBAC with global and project-scoped roles.

---

## 💡 Best Practices

- Put **all** logic in the shared library; a Jenkinsfile should be configuration only.
- Validate the caller's parameters at the top of the step — one clear error beats a `NullPointerException` 15 minutes in.
- Set `buildDiscarder` — unbounded build history is the most common cause of a full `JENKINS_HOME`.
- Set `timeout` and `disableConcurrentBuilds` — a hung build otherwise holds an executor forever.
- Always `cleanWs()` in `post { always }`; failed builds leave full `node_modules` trees behind.
- Run cheap gates first: tests before build, scan before push.
- Never interpolate a secret with Groovy `"${}"` — it lands in the script file and the console log.
- Use `retry(3)` for network operations; a Docker push is idempotent, so retrying is safe.
- Archive scan reports as artefacts so a blocked build can be diagnosed after the fact.
- Fail the build on a real problem; use `unstable` only for a documented, temporary baseline.

---

## 🌍 Real-World Use Cases

- **Standardised pipelines at scale** — 50 services, one library, one place to fix a bug.
- **Compliance gates** — provable evidence that no image ships with a known critical vulnerability.
- **Supply-chain security** — OCI provenance labels map every running container to a commit.
- **Multi-language monorepos** — one `language:` parameter selects the right toolchain.
- **Progressive rollout** — extend the library with canary or blue/green stages once, inherit everywhere.
- **Auditability** — every deployment is a signed Git commit, not an untraceable `kubectl apply`.

---

## 🧹 Cleanup

```bash
# Remove local images and scan reports from the agent
docker system prune -af
rm -f trivy-*.json trivy-*.txt

# Delete ECR images (or let the lifecycle policy expire them)
aws ecr batch-delete-image --repository-name ivolve-frontend \
  --image-ids imageTag=42-a1b2c3d
```

---

## ✅ Result

A **Groovy Shared Library** of eight reusable steps powering a **9-stage pipeline** across three microservices, with each `Jenkinsfile` reduced to ~15 lines of configuration. Every build runs language-aware unit tests, a SonarQube quality gate, a hardened multi-stage Docker build with OCI provenance labels, and a **blocking Trivy scan that prevents a vulnerable image from ever reaching ECR** — then hands off to GitOps by committing a Kustomize image update, using zero static AWS credentials.

**Next:** [Phase 6 — Continuous Deployment with ArgoCD →](../06-ArgoCD/)
