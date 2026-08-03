# 🐳 Phase 1: Containerization with Docker Compose

## 📌 Overview

This phase brings the complete four-tier application up on a single machine, so the whole system can be **built and tested locally before a single AWS resource is provisioned**.

That ordering is deliberate. Debugging a broken environment variable is a 30-second `docker compose logs` on a laptop; the same bug found after Terraform, Ansible, Jenkins and ArgoCD are involved is a 45-minute archaeology exercise across five layers. Everything that *can* be proven locally *should* be.

The deliverable is one `docker-compose.yml` that starts three microservices and MySQL, wires them together on a private network, and gates startup on real health checks.

---

# 📖 Understanding Docker Compose

Compose describes a **multi-container application** declaratively. Instead of four `docker run` commands with a dozen flags each — and the burden of remembering the correct order — you describe the desired end state and Compose reconciles reality to it.

```text
   Without Compose                      With Compose
┌──────────────────────────┐      ┌──────────────────────────┐
│ docker network create …  │      │ docker-compose.yml       │
│ docker volume create …   │      │                          │
│ docker run -d --name db  │      │ services:                │
│   -e MYSQL_ROOT_PASS=…   │      │   mysql: {…}             │
│   -v db:/var/lib/mysql … │      │   auth-service: {…}      │
│ sleep 40   # hope it's up│      │   roadmap-service: {…}   │
│ docker run -d --name auth│      │   frontend: {…}          │
│   --link db …            │      │                          │
│ …                        │      │ $ docker compose up -d   │
└──────────────────────────┘      └──────────────────────────┘
   imperative, order-dependent        declarative, dependency-aware
   no health awareness                health-gated startup
```

### Why `version:` is gone

The old `version: '3.8'` key is **obsolete**. Compose v2 derives the schema from the file contents, and leaving the key in produces:

```text
WARN[0000] the attribute `version` is obsolete, it will be ignored
```

Most tutorials still include it. This file does not.

---

# 📖 Understanding the Startup-Order Problem

This is the single most important thing Compose does for this stack.

`auth-service` opens a MySQL connection during startup. MySQL's *first* boot initialises its data directory, which takes 30–40 seconds. Naive orchestration produces this:

```text
t=0s   compose starts mysql and auth-service together
t=1s   auth-service connects → CONNECTION REFUSED → exits
t=2s   restart #1 → refused
t=5s   restart #2 → refused
t=40s  mysql is finally ready
t=40s  auth-service is in CrashLoopBackOff, backing off for 60s
t=100s  service finally recovers — 60s AFTER the database was ready
```

The fix has two parts, and **both are required**:

| Mechanism | What it does | Without it |
|---|---|---|
| `healthcheck` | Defines what "ready" *means* for a container | Compose only knows the process started |
| `depends_on: condition: service_healthy` | Waits for that check to pass | Waits only for container *creation* |

```yaml
mysql:
  healthcheck:
    test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -u root -p\"$$MYSQL_ROOT_PASSWORD\" --silent"]
    start_period: 40s      # ← grace window during first-boot initialisation
    interval: 10s
    retries: 10

auth-service:
  depends_on:
    mysql:
      condition: service_healthy    # ← NOT the bare `depends_on: [mysql]`
```

> 💡 **`start_period` is the subtle one.** During that window, a failing check does **not** count toward `retries`. Without it, MySQL is marked unhealthy while it is still legitimately initialising, and the dependent services never start at all.

---

# 📖 Understanding Container Networking

Compose creates a **user-defined bridge network**, which differs from Docker's default bridge in one decisive way: **automatic DNS resolution by service name**.

```text
        ivolve-net  (user-defined bridge)
   ┌──────────────────────────────────────────────┐
   │                                              │
   │  frontend ──── http://auth-service:5000 ───► auth-service
   │      │                                          │
   │      └──────── http://roadmap-service:8080 ──► roadmap-service
   │                                                 │
   │                                    mysql:3306 ◄─┘
   └──────────────────────────────────────────────┘
              ▲
              │ only :3000 published to the host
        localhost:3000
```

Docker runs an embedded DNS server at `127.0.0.11` inside each container. A lookup of `auth-service` returns that container's current IP — which is why the frontend's configuration contains a *name*, never an address:

```yaml
AUTH_SERVICE_URL: http://auth-service:5000
```

**This is the same pattern Kubernetes uses.** In Phase 4 the identical variable becomes `http://auth-service:5000`, resolved by CoreDNS instead of Docker's resolver. The application code never changes — only the resolver behind the name. That continuity is the reason local Compose testing is genuinely predictive of cluster behaviour.

### Port publishing, and why most ports are bound to loopback

| Service | Published as | Reachable from |
|---|---|---|
| `frontend` | `3000:3000` | Anywhere — this is the public entry point |
| `auth-service` | `127.0.0.1:5000:5000` | This machine only |
| `roadmap-service` | `127.0.0.1:8080:8080` | This machine only |
| `mysql` | `127.0.0.1:3306:3306` | This machine only |

Binding the backends to `127.0.0.1` keeps them available for `curl` and DBeaver while making them **unreachable from other machines on the LAN**. A bare `3306:3306` on a café Wi-Fi network publishes your database to the room.

---

# 📖 Understanding Volumes

MySQL writes to `/var/lib/mysql` inside the container. Container filesystems are ephemeral — remove the container and the data goes with it.

```text
   Named volume (used here)          Bind mount
┌────────────────────────────┐   ┌────────────────────────────┐
│ volumes:                   │   │ volumes:                   │
│   - mysql-data:/var/lib/…  │   │   - ./data:/var/lib/mysql  │
│                            │   │                            │
│ Docker manages the storage │   │ You manage a host path     │
│ Portable across OSes       │   │ Breaks on Windows/macOS    │
│                            │   │   (uid/gid mismatch)       │
│ Survives `down`            │   │ Visible in your editor     │
└────────────────────────────┘   └────────────────────────────┘
```

A **named volume** is used for MySQL because bind mounts hit permission problems on Windows and macOS — MySQL runs as uid 999 and cannot chown a host-mounted directory.

| Command | Effect on data |
|---|---|
| `docker compose down` | Volume **kept** — users survive |
| `docker compose down -v` | Volume **deleted** — database starts empty |

---

## 🎯 Objectives

- Build all three microservices from source with hardened multi-stage Dockerfiles.
- Run the complete stack — three services plus MySQL — with one command.
- Gate startup on real health checks so no service starts before its dependencies are ready.
- Isolate services on a user-defined bridge network with DNS-based discovery.
- Persist database state in a named volume across container recreation.
- Externalise every secret into a gitignored `.env` file.
- Apply resource limits, log rotation and capability dropping to every container.

---

## 📂 Project Structure

```text
01-Docker/
├── docker-compose.yml      # The complete stack definition
├── .env.example            # Template — copy to .env and fill in
└── README.md               # This file

src/                        # Build contexts referenced by the compose file
├── frontend/
│   ├── Dockerfile          # Node 22 · multi-stage · non-root · tini
│   └── .dockerignore
├── auth-service/
│   ├── Dockerfile          # Python 3.12 · wheel-build stage · gunicorn
│   └── .dockerignore
└── roadmap-service/
    ├── Dockerfile          # Maven build → JRE runtime · container-aware JVM
    └── .dockerignore
```

---

## 🛠 Technologies Used

- Docker Engine 24+
- Docker Compose v2
- BuildKit
- MySQL 8.0
- Node.js 22 (Alpine)
- Python 3.12 (slim) + gunicorn
- Java 21 (Eclipse Temurin JRE Alpine)
- `tini` — PID 1 init

---

## ✅ Prerequisites

- Docker Engine 24 or later with the Compose v2 plugin
  ```bash
  docker --version          # Docker version 24.x or later
  docker compose version    # Docker Compose version v2.x  (no hyphen)
  ```
- ~4 GB free RAM and ~5 GB free disk
- Ports `3000`, `5000`, `8080`, `3306` free on the host

---

# 📋 Steps

## 1. Create the environment file

Every secret is externalised. The Compose file uses `${VAR:?message}` syntax, which makes the variable **mandatory** — a missing value fails immediately with a clear message rather than silently starting MySQL with an empty root password.

```bash
cd 01-Docker
cp .env.example .env
```

Generate strong values:

```bash
# Linux / macOS / Git Bash
openssl rand -base64 24
```

```powershell
# Windows PowerShell
[Convert]::ToBase64String((1..24 | ForEach-Object { Get-Random -Maximum 256 }))
```

Edit `.env` and replace every `CHANGE_ME`:

```ini
MYSQL_ROOT_PASSWORD=<generated>
MYSQL_DATABASE=ivolve
MYSQL_USER=ivolve_user
MYSQL_PASSWORD=<generated>
SESSION_SECRET=<generated, 32 bytes>
```

> ⚠️ **`SESSION_SECRET` is not optional.** `src/frontend/server.js` falls back to the literal string `"change-me-in-k8s"`. Anyone who has read the public upstream repository knows that value and can forge a signed session cookie for any username — a complete authentication bypass.

---

## 2. Build and start the stack

```bash
docker compose up --build -d
```

Expected output:

```text
[+] Building 84.3s (38/38) FINISHED
 => [auth-service builder 4/5] RUN pip wheel --no-cache-dir …        22.1s
 => [roadmap-service build 5/6] RUN mvn -B clean package …           41.7s
 => [frontend deps 3/4] RUN npm install --omit=dev …                 11.2s
[+] Running 5/5
 ✔ Network ivolve-net                Created
 ✔ Volume  ivolve-mysql-data         Created
 ✔ Container ivolve-mysql            Healthy
 ✔ Container ivolve-roadmap-service  Healthy
 ✔ Container ivolve-auth-service     Healthy
 ✔ Container ivolve-frontend         Started
```

Note the ordering: `mysql` reaches **Healthy** before `auth-service` is even started. That is `condition: service_healthy` doing its job.

---

## 3. Verify health

```bash
docker compose ps
```

```text
NAME                     STATUS                    PORTS
ivolve-mysql             Up 2 minutes (healthy)    127.0.0.1:3306->3306/tcp
ivolve-auth-service      Up 1 minute (healthy)     127.0.0.1:5000->5000/tcp
ivolve-roadmap-service   Up 1 minute (healthy)     127.0.0.1:8080->8080/tcp
ivolve-frontend          Up 1 minute (healthy)     0.0.0.0:3000->3000/tcp
```

All four must show `(healthy)`. A container stuck at `(health: starting)` for more than its `start_period` needs investigating with `docker compose logs <service>`.

---

## 4. Test the services directly

```bash
# Auth service — checks its own database connectivity
curl -s http://localhost:5000/health
```
```json
{"database":"connected","status":"UP"}
```

```bash
# Roadmap service — returns the eight roadmap topics
curl -s http://localhost:8080/api/roadmap | head -c 200
```
```json
[{"description":"Learn Linux commands, processes, networking and shell scripting.","title":"OS"},…
```

```bash
# Create a user through the auth API
curl -s -X POST http://localhost:5000/api/auth/signup \
  -H 'Content-Type: application/json' \
  -d '{"username":"waleed","password":"SuperSecret123"}'
```
```json
{"message":"User created successfully."}
```

---

## 5. Test through the browser

Open **<http://localhost:3000>**.

1. Click **Sign up**, create an account (username ≥ 3 chars, password ≥ 8 chars).
2. Log in — the frontend calls `auth-service`, which validates the bcrypt hash against MySQL.
3. You land on the **DevOps Roadmap** page, rendered from `roadmap-service`.

---

## 6. Verify service discovery

Prove that DNS resolution between containers works:

```bash
docker compose exec frontend sh -c "getent hosts auth-service roadmap-service"
```
```text
172.19.0.3      auth-service
172.19.0.4      roadmap-service
```

The frontend reached both by **name**, not by IP. Exactly as it will in Kubernetes.

---

## 7. Verify persistence

```bash
docker compose down          # stop containers, KEEP the volume
docker compose up -d
```

Log in with the account created in step 5 — it still exists. The named volume survived.

```bash
docker volume inspect ivolve-mysql-data --format '{{.Mountpoint}}'
```

---

## 8. Verify the security hardening

```bash
# Every service runs as a non-root user
for s in frontend auth-service roadmap-service; do
  printf "%-18s " "$s"; docker compose exec -T $s id
done
```
```text
frontend           uid=1000(node) gid=1000(node)
auth-service       uid=10001(appuser) gid=10001(appuser)
roadmap-service    uid=10001(appuser) gid=10001(appgroup)
```

```bash
# Image sizes — the payoff from multi-stage builds
docker images | grep ivolve
```

---

# 📸 Screenshots

| Description | Image |
|---|---|
| `docker compose up --build` completing with all services healthy | `Screenshots/compose_up.png` |
| `docker compose ps` showing four healthy containers | `Screenshots/compose_ps.png` |
| Login / signup page at `localhost:3000` | `Screenshots/app_auth.png` |
| DevOps Roadmap page after login | `Screenshots/app_roadmap.png` |
| `curl /health` and `curl /api/roadmap` responses | `Screenshots/api_tests.png` |
| Data surviving `down` → `up` | `Screenshots/persistence.png` |

---

## 📚 Key Learning Outcomes

- Model a multi-container application declaratively with Compose v2.
- Distinguish `depends_on` (creation order) from `condition: service_healthy` (readiness) — and know why only the latter prevents crash loops.
- Use `start_period` so slow-initialising containers are not killed while legitimately starting.
- Understand user-defined bridge networks and DNS-based service discovery, and how it maps onto Kubernetes.
- Choose named volumes over bind mounts for database state, and know why on Windows/macOS.
- Externalise configuration with `.env` and enforce required values via `${VAR:?message}`.
- Build multi-stage images that drop build tooling from the runtime layer.
- Apply per-container resource limits, log rotation and `cap_drop: ALL`.

---

## 💡 Best Practices

- **Never** commit `.env` — commit `.env.example` instead so required keys are documented without leaking values.
- Use `${VAR:?message}` for anything mandatory; fail loudly at parse time rather than mysteriously at runtime.
- Give every service a `healthcheck`, then gate dependants on `service_healthy`.
- Bind non-public ports to `127.0.0.1` so they are not exposed to the local network.
- Cap logs with `max-size`/`max-file` — the default `json-file` driver is unbounded and will fill the disk.
- Set `deploy.resources.limits` so one runaway container cannot starve the host.
- Add `security_opt: no-new-privileges` and `cap_drop: ALL`; none of these services need any Linux capability.
- Use `tini` (or `--init`) as PID 1 so `SIGTERM` is forwarded and zombies are reaped.
- Pin image tags (`mysql:8.0`, not `mysql:latest`) so a rebuild months from now is the same build.
- Add a `.dockerignore` per service — it keeps `.env` and `node_modules` out of the build context and out of the image.

---

## 🌍 Real-World Use Cases

- **Local development environments** — a new engineer runs one command instead of following a 20-step wiki page.
- **Integration testing in CI** — spin up the real database rather than mocking it, then tear it down.
- **Reproducing production bugs** — same images, same wiring, on a laptop.
- **Demo environments** for stakeholders, with no cloud cost.
- **Pre-flight validation** before an expensive Kubernetes deployment.
- **Onboarding documentation that cannot rot** — the Compose file *is* the environment specification.

---

## 🧹 Cleanup

```bash
# Stop containers, keep the database
docker compose down

# Stop containers AND delete the database volume
docker compose down -v

# Also remove the images built here
docker compose down -v --rmi local

# Reclaim everything Docker is holding (affects other projects too)
docker system prune -af --volumes
```

---

## ✅ Result

A complete four-tier application — **Node.js frontend, Python auth service, Java roadmap service and MySQL** — running locally from a single `docker compose up`, with health-gated startup ordering, DNS-based service discovery on an isolated bridge network, persistent database storage, externalised secrets, and every container running unprivileged as a non-root user with all Linux capabilities dropped.

Validated with `docker compose config` ✅

**Next:** [Phase 2 — Infrastructure Provisioning with Terraform →](../02-Terraform/)
