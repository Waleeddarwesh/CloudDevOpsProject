# 🤖 Phase 3: Configuration Management with Ansible

## 📌 Overview

Terraform provisioned a bare Ubuntu 22.04 instance. This phase turns it into a fully-equipped CI server — Java, Jenkins, Docker, Trivy, AWS CLI, kubectl, Helm and SonarQube — using **9 Ansible roles**, an **AWS dynamic inventory**, and **Ansible Vault** for secrets.

**No IP address appears anywhere in this repository.** Ansible queries the EC2 API at runtime and finds the instance by tag.

---

# 📖 Understanding Provisioning vs Configuration

Terraform and Ansible are complementary, not competing. Confusing their roles is a common design mistake.

```text
┌──────────────────────────────────────────────────────────────┐
│                   Infrastructure Pipeline                    │
│                                                              │
│  ┌───────────┐   creates    ┌────────────┐   configures      │
│  │ Terraform │ ───────────► │  EC2       │ ◄──────────────   │
│  │  (IaC)    │  the machine │  instance  │  the software     │
│  └───────────┘              └─────┬──────┘        ▲          │
│        │                          │               │          │
│        │  tags it Role=jenkins    │               │          │
│        └──────────────────────────┴───────────────┘          │
│                                          ┌─────────────┐     │
│                                          │   Ansible   │     │
│                                          │ dynamic inv │     │
│                                          └─────────────┘     │
└──────────────────────────────────────────────────────────────┘
```

| Tool | Owns | Failure mode if misused |
|---|---|---|
| **Terraform** | The *machine* — instance, disk, network, IAM | Installing packages in `user_data` means fixing a typo requires **destroying the instance**, losing all Jenkins build history |
| **Ansible** | The *software* — packages, services, config files | Idempotent and re-runnable; adding a tool is a 30-second re-run |

> 💡 **The tag is the bridge.** Terraform sets `Role = jenkins` on the instance; Ansible's dynamic inventory filters on `tag:Role: jenkins`. Change either string and Phase 3 finds nothing — they must stay in sync.

This is why [`user_data.sh`](../02-Terraform/modules/server/user_data.sh) does the absolute minimum (patches, Python, a swap file) and writes a marker file that the playbook waits on.

---

# 📖 Understanding Dynamic Inventory

A static inventory is a hand-maintained list of addresses. In a cloud workflow it is wrong the moment Terraform replaces an instance.

```text
   Static inventory                    Dynamic inventory (used here)
┌───────────────────────────┐     ┌──────────────────────────────────┐
│ [jenkins]                 │     │ plugin: amazon.aws.aws_ec2       │
│ 54.211.103.22             │     │ regions: [us-east-1]             │
│                           │     │ filters:                         │
│ ✗ edit after every apply  │     │   tag:Role: jenkins              │
│ ✗ silently targets a      │     │   instance-state-name: running   │
│   dead host after replace │     │                                  │
│ ✗ no tag awareness        │     │ ✓ queried live from the EC2 API  │
└───────────────────────────┘     │ ✓ groups built from tags         │
                                  └──────────────────────────────────┘
```

```text
┌────────────┐  filters: tag:Role=jenkins  ┌─────────────┐
│  Ansible   │ ──────────────────────────► │   EC2 API   │
│  Control   │ ◄────────────────────────── └─────────────┘
└────────────┘   group: role_jenkins → 54.x.x.x
```

Two settings matter more than they look:

| Setting | Why |
|---|---|
| `instance-state-name: running` | Without it, **terminated instances are still returned** — AWS keeps them visible in the API for ~1 hour — and the playbook wastes 30s timing out against a machine that no longer exists |
| Filename must end `aws_ec2.yml` | The plugin refuses to load any other filename, and the play reports `skipping: no hosts matched` with no explanation |

> 💡 **Note the double quoting in `compose`:** `ansible_user: "'ubuntu'"`. The expression is evaluated as Jinja, so a literal string needs quoting twice. A single-quoted `"ubuntu"` would be treated as an undefined *variable*.

---

# 📖 Understanding Roles

A role packages tasks, variables, handlers, templates and metadata into a reusable unit with a standard directory layout.

```text
roles/jenkins/
├── tasks/main.yml       # what to do
├── defaults/main.yml    # overridable variables (LOWEST precedence)
├── handlers/main.yml    # restart triggers — run once, only if notified
├── templates/           # Jinja2 templates
│   └── override.conf.j2
└── meta/main.yml        # dependencies + metadata
```

### Role dependency graph

`meta/main.yml` declares dependencies, and Ansible runs each role **only once** per play even when several roles depend on it:

```text
        common
        ├── java ────────┐
        ├── docker ──────┤
        │   └── sonarqube│
        ├── trivy        ├──► jenkins
        ├── aws_cli      │
        ├── kubectl      │
        └── helm         │
```

Ordering is not cosmetic:

| Dependency | Consequence of getting it wrong |
|---|---|
| `java` **before** `jenkins` | The Jenkins package declares **no JRE dependency**. Install it without a JVM and the service fails to start with a bare `Failed with result 'exit-code'` and nothing useful in the journal. |
| `docker` **before** `jenkins` | The `docker` group must exist before the `jenkins` user can be added to it. |

---

# 📖 Understanding Idempotency

An idempotent playbook produces the same result whether it runs once or fifty times. The second run should report **`changed=0`**.

```text
  Run 1:  ok=42  changed=31   ← did the work
  Run 2:  ok=42  changed=0    ← nothing left to do  ✅ idempotent
```

Techniques used throughout these roles:

| Technique | Example | Why |
|---|---|---|
| `creates:` on `command` | `creates: /etc/apt/keyrings/docker.gpg` | Ansible skips the task entirely if the file exists |
| `changed_when: false` | `apt update`, version checks | Read-only actions must not count as changes |
| Declarative state | `state: present` | Ansible checks before acting |
| `force: false` on `get_url` | GPG keys | Do not re-download an unchanged file every run |

> ⚠️ **Why `apt_key` is not used.** The deprecated `apt_key` module wrote every key into one shared `trusted.gpg`, where **any** trusted key could sign **any** repository — a real supply-chain risk. These roles download keys to `/etc/apt/keyrings/` and bind each repository to its own key with `signed-by=`.

---

# 📖 Understanding Ansible Vault

Vault encrypts variable files with AES-256 so secrets can live safely in Git.

```text
   group_vars/all/main.yml          group_vars/all/vault.yml
┌────────────────────────────┐   ┌────────────────────────────────┐
│ # committed as plaintext   │   │ $ANSIBLE_VAULT;1.1;AES256      │
│ jenkins_http_port: 8080    │   │ 62313435643764363...           │
│ sonarqube_port: 9000       │   │ 39306462643264663...           │
│                            │   │ ← unreadable without the key   │
│ non-sensitive config       │   │    committed SAFELY            │
└────────────────────────────┘   └────────────────────────────────┘
                       ▲
              .vault_pass (gitignored)
```

### The `vault_` prefix convention

Every secret is named `vault_something` and indirected through a plain variable:

```yaml
# defaults/main.yml
sonarqube_admin_password: "{{ vault_sonarqube_admin_password }}"
```

This exists for a practical reason: **an encrypted file is opaque to `grep`**. Without the prefix, seeing `sonarqube_admin_password` in a task tells you nothing about where the value comes from.

| Command | Purpose |
|---|---|
| `ansible-vault encrypt <file>` | Encrypt in place |
| `ansible-vault view <file>` | Read without decrypting to disk |
| `ansible-vault edit <file>` | Edit; re-encrypts on save |
| `ansible-vault rekey <file>` | Change the password |

> ⚠️ **Lose `.vault_pass` and the vault is unrecoverable.** AES-256 with no backdoor and no reset. Store it in a password manager.

---

## 🎯 Objectives

- Discover the Jenkins EC2 instance automatically via the **AWS dynamic inventory** plugin.
- Install **Java**, **Jenkins**, and the required packages (**Docker**, **Trivy**).
- Additionally install AWS CLI v2, kubectl, Helm and SonarQube.
- Structure everything as **Ansible roles** with dependencies, handlers and templates.
- Protect all secrets with **Ansible Vault**.
- Guarantee idempotency — a second run reports `changed=0`.

---

## 📂 Project Structure

```text
03-Ansible/
├── ansible.cfg                     # inventory, SSH multiplexing, vault path
├── playbook.yml                    # pre_tasks → 9 roles → post_tasks
├── requirements.yml                # Galaxy collections
├── .vault_pass.example             # → copy to .vault_pass (gitignored)
│
├── inventory/
│   └── aws_ec2.yml                 # AWS dynamic inventory
│
├── group_vars/all/
│   ├── main.yml                    # non-sensitive config + plugin list
│   └── vault.yml.example           # → encrypt as vault.yml
│
└── roles/
    ├── common/       # base packages, timezone, sysctl, log caps, auto-updates
    ├── java/         # OpenJDK 17 + JAVA_HOME + alternatives
    ├── docker/       # Engine, Buildx, Compose v2, daemon.json, log rotation
    ├── jenkins/      # LTS repo, package, 25 plugins, systemd override, JVM tuning
    ├── trivy/        # Aqua APT repo, shared cache, nightly DB refresh
    ├── aws_cli/      # AWS CLI v2 from the official bundle
    ├── kubectl/      # pkgs.k8s.io, version hold, completion
    ├── helm/         # Helm 3 + 4 chart repositories
    └── sonarqube/    # SonarQube LTS + PostgreSQL via Docker Compose
```

---

## 🛠 Technologies Used

- Ansible Core 2.15+
- Collections: `amazon.aws`, `community.docker`, `community.general`, `ansible.posix`
- Ansible Vault (AES-256)
- Python 3 · boto3 / botocore
- Jinja2 templating
- Ubuntu 22.04 LTS · APT · systemd

---

## ✅ Prerequisites

- [Phase 2](../02-Terraform/) applied — the Jenkins instance must exist and be tagged `Role=jenkins`.
- Ansible and the Python AWS SDK:
  ```bash
  pip install ansible-core boto3 botocore
  ansible --version
  ```
- Collections:
  ```bash
  ansible-galaxy collection install -r requirements.yml
  ```
- AWS credentials (the plugin uses the standard boto3 chain):
  ```bash
  aws sts get-caller-identity
  ```
- The SSH private key at `~/.ssh/ivolve-key.pem` with mode `400`.

---

# 📋 Steps

## 1. Create the Vault

```bash
cd 03-Ansible

# Generate a strong vault password (gitignored)
openssl rand -base64 32 > .vault_pass
chmod 600 .vault_pass

# Create the vault from the template
cp group_vars/all/vault.yml.example group_vars/all/vault.yml
```

Edit `group_vars/all/vault.yml` and replace every `CHANGE_ME`, then encrypt it:

```bash
ansible-vault encrypt group_vars/all/vault.yml
```

Verify it is genuinely encrypted:

```bash
head -1 group_vars/all/vault.yml
```
```text
$ANSIBLE_VAULT;1.1;AES256
```

> 💡 `ansible.cfg` sets `vault_password_file = ./.vault_pass`, so `ansible-playbook` decrypts automatically — no `--ask-vault-pass` needed.

---

## 2. Verify dynamic inventory

Before running anything, confirm Ansible can *find* the server:

```bash
ansible-inventory --graph
```
```text
@all:
  |--@aws_ec2:
  |  |--ivolve-dev-jenkins
  |--@role_jenkins:
  |  |--ivolve-dev-jenkins
  |--@env_dev:
  |  |--ivolve-dev-jenkins
  |--@az_us_east_1a:
  |  |--ivolve-dev-jenkins
  |--@jenkins_servers:
  |  |--ivolve-dev-jenkins
```

Inspect the resolved host variables:

```bash
ansible-inventory --host ivolve-dev-jenkins
```
```json
{
    "ansible_host": "54.211.x.x",
    "ansible_user": "ubuntu",
    "ansible_ssh_private_key_file": "~/.ssh/ivolve-key.pem",
    "ec2_instance_id": "i-0abc123def456789",
    "ec2_instance_type": "t3.medium"
}
```

Test connectivity:

```bash
ansible role_jenkins -m ping
```
```text
ivolve-dev-jenkins | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
```

> 🔧 **Empty inventory?** See [Troubleshooting](#-troubleshooting) below.

---

## 3. Dry run

```bash
ansible-playbook playbook.yml --check --diff
```

`--check` makes no changes; `--diff` shows exactly what would be modified. Always look before you run.

---

## 4. Run the playbook

```bash
ansible-playbook playbook.yml
```

⏱ **Expect 8–12 minutes** — mostly Jenkins plugin downloads and the SonarQube image pull.

```text
PLAY [Configure Jenkins CI server] *********************************************

TASK [Wait for the instance to accept SSH connections] *************************
ok: [ivolve-dev-jenkins]

TASK [Verify the target is Ubuntu 22.04] ***************************************
ok: [ivolve-dev-jenkins] => {
    "msg": "Target OS verified: Ubuntu 22.04"
}

TASK [common : Install baseline packages] **************************************
changed: [ivolve-dev-jenkins]

TASK [java : Install OpenJDK 17] ***********************************************
changed: [ivolve-dev-jenkins]

TASK [docker : Install Docker Engine and plugins] ******************************
changed: [ivolve-dev-jenkins]

TASK [jenkins : Install Jenkins] ***********************************************
changed: [ivolve-dev-jenkins]

TASK [jenkins : Install the Jenkins plugins] ***********************************
changed: [ivolve-dev-jenkins]

TASK [trivy : Install Trivy] ***************************************************
changed: [ivolve-dev-jenkins]

TASK [sonarqube : Start the SonarQube stack] ***********************************
changed: [ivolve-dev-jenkins]

TASK [Display the setup summary] ***********************************************
ok: [ivolve-dev-jenkins] => {
    "msg": [
        "══════════════════════════════════════════════════",
        " Jenkins CI server is ready",
        "══════════════════════════════════════════════════",
        " Jenkins UI    http://54.211.x.x:8080",
        " SonarQube     http://54.211.x.x:9000",
        " Initial admin password:",
        " a1b2c3d4e5f6789012345678abcdef01",
        …
    ]
}

PLAY RECAP *********************************************************************
ivolve-dev-jenkins : ok=68  changed=41  unreachable=0  failed=0  skipped=2
```

---

## 5. Prove idempotency

Run it again immediately:

```bash
ansible-playbook playbook.yml
```
```text
PLAY RECAP *********************************************************************
ivolve-dev-jenkins : ok=68  changed=0   unreachable=0  failed=0  skipped=2
```

**`changed=0`** — the playbook made no changes because the server already matches the declared state. This is the property that makes it safe to re-run any time.

---

## 6. Targeted runs with tags

```bash
ansible-playbook playbook.yml --tags docker        # only the docker role
ansible-playbook playbook.yml --tags jenkins,ci    # Java + Docker + Jenkins
ansible-playbook playbook.yml --skip-tags sonarqube
ansible-playbook playbook.yml --tags security      # just Trivy
```

---

## 7. Verify on the server

```bash
ssh -i ~/.ssh/ivolve-key.pem ubuntu@$(terraform -chdir=../02-Terraform output -raw jenkins_public_ip)
```

```bash
java -version                # openjdk 17.x
systemctl is-active jenkins  # active
docker --version             # Docker version 27.x
docker compose version       # v2.x
trivy --version              # Version: 0.5x
aws --version                # aws-cli/2.x
kubectl version --client     # v1.31.x
helm version --short         # v3.x

# The instance profile supplies credentials — no static keys anywhere
aws sts get-caller-identity
# → arn:aws:sts::991216470475:assumed-role/ivolve-dev-jenkins-role/i-0abc...

# jenkins can use Docker without sudo
sudo -u jenkins docker ps
```

---

## 8. Complete the Jenkins setup

Open `http://<JENKINS_IP>:8080` and unlock with the password from the playbook summary (or read it directly):

```bash
ansible role_jenkins -m command -a 'cat /var/lib/jenkins/secrets/initialAdminPassword' --become
```

Then configure:

1. **Manage Jenkins → System → Global Pipeline Libraries**
   - Name: `shared-library`
   - Default version: `main`
   - Retrieval: *Modern SCM* → *Git* → your shared-library repository
2. **Manage Jenkins → Credentials** — add `github-token` and `sonar-token`
3. **Manage Jenkins → System → SonarQube servers** — name `sonarqube`, URL `http://localhost:9000`

Full detail in [Phase 5](../05-Jenkins/).

---

## 🔧 Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `skipping: no hosts matched` | Plugin not enabled, or file misnamed | Confirm `enable_plugins = amazon.aws.aws_ec2` in `ansible.cfg` and that the file is `inventory/aws_ec2.yml` |
| Inventory empty after `terraform apply` | Cached inventory | `ansible-inventory --graph --flush-cache`, or delete `.ansible_inventory_cache` |
| `Failed to connect ... via ssh` | Your IP changed | Update `allowed_ssh_cidrs` in `terraform.tfvars` and re-apply |
| `UNREACHABLE ... Permission denied (publickey)` | Key permissions | `chmod 400 ~/.ssh/ivolve-key.pem` |
| `Could not get lock /var/lib/dpkg/lock-frontend` | `user_data` still running | The playbook waits on `/etc/ivolve-bootstrap-complete`; if it timed out, wait and re-run |
| `Attempting to decrypt but no vault secrets found` | Missing `.vault_pass` | Create it, or pass `--ask-vault-pass` |
| Jenkins service dead after install | Java missing | The `java` role must run first — check `meta/main.yml` dependencies |
| SonarQube exits immediately | `vm.max_map_count` too low | The `common` role sets it to 262144; verify with `sysctl vm.max_map_count` |

---

# 📸 Screenshots

| Description | Image |
|---|---|
| `ansible-inventory --graph` discovering the host | `Screenshots/dynamic_inventory.png` |
| `ansible role_jenkins -m ping` | `Screenshots/ansible_ping.png` |
| Encrypted `vault.yml` contents | `Screenshots/vault_encrypted.png` |
| Playbook run with `PLAY RECAP` | `Screenshots/playbook_run.png` |
| Second run showing `changed=0` | `Screenshots/idempotency.png` |
| Installed tool versions on the server | `Screenshots/tool_versions.png` |
| Jenkins unlock screen | `Screenshots/jenkins_unlock.png` |
| SonarQube dashboard | `Screenshots/sonarqube_ui.png` |

---

## 📚 Key Learning Outcomes

- Separate provisioning (Terraform) from configuration (Ansible), and use tags as the bridge.
- Configure the `amazon.aws.aws_ec2` dynamic inventory plugin with filters, `keyed_groups` and `compose`.
- Structure reusable roles with `tasks`, `defaults`, `handlers`, `templates` and `meta` dependencies.
- Write idempotent tasks using `creates:`, `changed_when:` and declarative state.
- Encrypt secrets with Ansible Vault and use the `vault_` indirection convention.
- Understand why `apt_key` is deprecated and how `signed-by=` keyrings fix the trust model.
- Use handlers so services restart **once**, and only when something actually changed.
- Configure services safely with systemd **drop-in overrides** rather than editing packaged units.

---

## 💡 Best Practices

- Use **FQCN** (`ansible.builtin.apt`, not `apt`) — unambiguous and future-proof.
- Give every task a clear `name:`; it is the log output during an incident.
- `defaults/` for overridable values, `vars/` for values that must not be overridden.
- Never commit `.vault_pass`; commit the **encrypted** vault, never a plaintext copy.
- Prefer handlers to inline restarts — five config changes should cause one restart, not five.
- Add `validate:` to `template`/`copy` for config files that can break a service (this repo validates `daemon.json` as JSON before writing it).
- Use `--check --diff` before every real run.
- Pin versions in `group_vars` rather than tracking `latest`.
- Enable SSH `pipelining` and `ControlPersist` — typically 30-50% faster playbook runs.
- Assert your assumptions in `pre_tasks` (OS version, disk space) so failures are explained, not mysterious.

---

## 🌍 Real-World Use Cases

- **Auto-scaling fleets** — dynamic inventory configures instances the moment they appear.
- **Golden-image pipelines** — Ansible + Packer produce reproducible AMIs.
- **Compliance enforcement** — re-run the playbook on a schedule to correct drift automatically.
- **Multi-region deployments** — the same roles against different inventory filters.
- **Disaster recovery** — Terraform rebuilds the infrastructure, Ansible reconfigures it, with no manual steps.
- **Secrets rotation** — `ansible-vault rekey` then re-run.
- **Onboarding** — a new engineer's environment is a playbook, not a wiki page.

---

## 🧹 Cleanup

```bash
# Remove local caches, logs and secrets
rm -rf .ansible_facts .ansible_inventory_cache ansible.log
rm -f .vault_pass

# The server itself is destroyed by Terraform
cd ../02-Terraform && terraform destroy
```

---

## ✅ Result

A bare Ubuntu instance transformed into a fully-provisioned CI server by **9 idempotent Ansible roles**, targeted through **AWS dynamic inventory** with no hardcoded addresses, and with every credential protected by **Ansible Vault**. The server runs Jenkins LTS with 25 declaratively-installed plugins and JVM tuning, Docker Engine with Compose v2 and log rotation, Trivy with a pre-warmed vulnerability database and a nightly refresh, AWS CLI v2 authenticating through the EC2 instance profile, kubectl and Helm, and SonarQube LTS backed by PostgreSQL.

**Validated:** all 40 YAML files parse ✅ · second run reports `changed=0` ✅

**Next:** [Phase 4 — Container Orchestration with Kubernetes →](../04-Kubernetes/)
