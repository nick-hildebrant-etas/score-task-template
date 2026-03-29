# ARM Build Platform — Project Plan

> Single Mac Mini · K3s · Nexus · Buildbarn · GitHub Actions · ARM64

---

## 1. Architecture overview

The platform runs entirely on a single Apple Silicon Mac Mini. K3s hosts all persistent services as Helm-managed pods. Build isolation is provided by Firecracker micro-VMs (ARM64) launched on demand as K3s Jobs. GitHub Actions drives CI via a self-hosted runner; Nexus serves as the unified artifact and container cache; Buildbarn provides Remote Build Execution (RBE) over the REAPI protocol so Bazel submits hundreds of actions in parallel without any custom orchestration layer.

### 1.1 Component summary

| Layer | Component | Role |
|---|---|---|
| Hardware | Apple Silicon Mac Mini | Single ARM64 host — all workloads run here |
| Hypervisor | Virtualization.framework / KVM shim | Provides `/dev/kvm` for Firecracker µVMs |
| Orchestration | K3s (single-node) | Kubernetes control plane + containerd runtime |
| Artifact store | Sonatype Nexus OSS (`nxrm-ha` chart) | Maven, pip, Cargo, npm proxy + Docker registry |
| Database | PostgreSQL (Bitnami chart) | Backing store for Nexus — embedded DB not safe on K8s |
| Remote execution | Buildbarn (scheduler + storage + workers) | REAPI server; Bazel submits actions, workers run in µVMs |
| Build workers | Firecracker µVMs — Alpine ARM64 (initial) | Isolated per-build VMs; swapped for custom rootfs later |
| CI trigger | GitHub Actions + self-hosted runner | Matrix strategy fans out across 30 repos |
| Dep warming | `task deps:collect` + `task deps:seed` | Scrapes lockfiles, warms Nexus proxy caches via K3s Job |
| Secrets | SOPS + age → `.env` | All credentials injected via `.env`; nothing committed |

### 1.2 Data flow

```
developer push (any of 30 repos)
  → GitHub Actions matrix (fail-fast: false, one leg per repo)
    → self-hosted runner pod (actions-runner-controller)
      → bazel test //... --remote_executor=grpc://bb-scheduler:8980
        → Buildbarn scheduler fans actions to Firecracker workers
          → each worker pulls rootfs from Nexus Docker registry
          → deps resolved from Nexus proxy repos (warm cache)
          → results stream back to Bazel via REAPI WaitExecution
        → GHA reports pass/fail per matrix leg
```

### 1.3 Taskfile structure

```
Taskfile.yml              # root — includes all modules, defines `up` and `down`
tasks/
  k3s.yml                 # install, configure, uninstall K3s
  storage.yml             # namespaces + verify local-path PVC provisioner
  postgres.yml            # Bitnami PostgreSQL Helm install/upgrade/uninstall
  nexus.yml               # nxrm-ha Helm install, wait-for-ready, REST API config
  deps.yml                # collect (scrape lockfiles) + seed (warm Nexus via K3s Job)
  buildbarn.yml           # bb-storage, bb-scheduler, bb-worker install
  images.yml              # build Alpine ARM64 worker image, push to Nexus
  test.yml                # smoke tests — submit Bazel targets via RBE, assert results
  dev.yml                 # port-forwards, live logs, cluster status
```

---

## 2. Conventions

### 2.1 Story points

All features are sized at exactly 5 story points. Each is independently deliverable, has a working acceptance test executable as a Taskfile task, and leaves the system in a stable runnable state on completion.

### 2.2 Definition of done

- Helm release or resource deployed and shows `Ready` / `Running`
- Acceptance test task exits `0`
- `task dev:status` shows no `CrashLoopBackOff` or stuck `Pending` pods in the feature's namespace
- All secrets sourced from `.env` — nothing hardcoded

### 2.3 `.env` contract

Decrypted by SOPS + age before any task runs. Sourced via `dotenv: [.env]` in every Taskfile.

```
POSTGRES_PASSWORD
NEXUS_ADMIN_PASSWORD
NEXUS_DOCKER_PORT
BB_SCHEDULER_ADDR
GITHUB_ORG
RUNNER_TOKEN
SOPS_AGE_KEY_FILE        # path to age private key
```

---

## 3. Milestone map

| Milestone | Features | Deliverable |
|---|---|---|
| M1 — Foundation | F-00 F-01 F-02 F-03 | Claude Code installed, K3s running, namespaces ready, Postgres healthy |
| M2 — Artifact store | F-04 F-05 | Nexus up, all proxy repos configured, Docker registry live |
| M3 — Dep warming | F-06 F-07 | Central dep list generated, Nexus caches warm for all ecosystems |
| M4 — Build execution | F-08 F-09 F-10 | Worker image in Nexus, Buildbarn RBE accepting Bazel actions |
| M5 — CI integration | F-11 F-12 | GHA runner in K3s, matrix build across sample repos passing |
| M6 — Hardening | F-13 F-14 | Resource limits, PVC backup, full smoke suite in CI |

---

## 4. Feature backlog

Features are in delivery order. Each block shows the tasks introduced and the acceptance test that must pass before the feature is closed.

---

### Milestone 1 — Foundation

---

#### ~~F-00 · Claude Code install · 5 pts~~ ✓ DONE

**Tasks introduced**
- `task tools:install-npm`
- `task tools:install-claude`

**Acceptance tests**
- `task tools:test-claude` — `claude --version` exits `0`
- `which claude` returns a path under the npm global bin directory

**Notes**

`tools:install-npm` installs Node.js + npm via Homebrew (`brew install node`). `tools:install-claude` runs `npm install -g @anthropic-ai/claude-code`. Both are idempotent — re-running on an already-configured host is a no-op.

---

#### ~~F-01 · K3s install & verify · 5 pts~~ ✓ DONE

**Tasks introduced**
- `task k3s:install`
- `task k3s:status`
- `task k3s:uninstall`

**Acceptance tests**
- `task k3s:test` — `kubectl get nodes` returns 1 `Ready` ARM64 node
- `kubectl version --server` responds in under 5 seconds

---

#### ~~F-02 · Namespaces & storage · 5 pts~~ ✓ DONE

**Tasks introduced**
- `task storage:setup`
- `task storage:verify`

**Acceptance tests**
- `task storage:test` — PVC in each namespace binds via `local-path-provisioner`
- All 5 namespaces exist: `nexus`, `postgres`, `buildbarn`, `actions-runner`, `monitoring`

---

#### ~~F-03 · PostgreSQL deploy · 5 pts~~ ✓ DONE

**Tasks introduced**
- `task postgres:install`
- `task postgres:wait`
- `task postgres:uninstall`

**Acceptance tests**
- `task postgres:test` — `psql` ping from in-cluster Job returns `0`
- Data persists across pod restart (PVC re-mount check)

---

### Milestone 2 — Artifact store

---

#### F-04 · Nexus deploy & wait · 5 pts

**Tasks introduced**
- `task nexus:install`
- `task nexus:wait`
- `task nexus:uninstall`

**Acceptance tests**
- `task nexus:test-up` — `GET /service/rest/v1/status` returns HTTP 200
- Nexus pod survives 2 restarts with blob data intact (PVC check)

---

#### F-05 · Nexus repo configuration · 5 pts

**Tasks introduced**
- `task nexus:configure`
- `task nexus:list-repos`

**Acceptance tests**
- `task nexus:test-repos` — all proxy repos (maven, pypi, cargo, npm, docker, helm, apt, raw) return 200 on browse
- Docker registry responds on `$NEXUS_DOCKER_PORT` with a valid `/v2/` ping

---

### Milestone 3 — Dependency warming

---

#### F-06 · Central dep list generation · 5 pts

**Tasks introduced**
- `task deps:collect`
- `task deps:diff`
- `task deps:commit`

**Acceptance tests**
- `task deps:test-collect` — `deps/maven.txt`, `deps/pip.txt`, `deps/cargo.txt`, `deps/npm.txt` all non-empty after running against repo fixtures
- No duplicate coordinates in any file (dedup assertion)

**Notes**

`deps:collect` clones/pulls each of the 30 repos (or reads from local paths), extracts coords from each ecosystem's lockfile (`MODULE.bazel.lock`, `requirements.lock`, `Cargo.lock`, `pnpm-lock.yaml`), deduplicates, and writes the four files. Each repo can also export its own deps via `task deps:export` which opens a PR against the infra repo — the collect task then just merges those exports.

---

#### F-07 · Nexus cache warming · 5 pts

**Tasks introduced**
- `task deps:seed`
- `task deps:verify-cache`

**Acceptance tests**
- `task deps:test-seed` — K3s Job exits `0`; spot-check 5 random deps from each ecosystem resolve from Nexus cache, not upstream
- Nexus browse shows cached assets in each proxy repo

**Notes**

`deps:seed` launches a K3s Job (ARM64) that runs `mvn dependency:get`, `pip download`, `cargo fetch`, and `pnpm fetch` all pointed at the Nexus proxy URLs. No Temporal — a single Job is sufficient for a one-shot warm.

---

### Milestone 4 — Build execution

---

#### F-08 · Alpine ARM64 worker image · 5 pts

**Tasks introduced**
- `task images:build-worker`
- `task images:push-worker`
- `task images:list`

**Acceptance tests**
- `task images:test` — `docker pull nexus.local:5000/build-worker:alpine-arm64` exits `0`
- `uname -m` inside the pulled image returns `aarch64`

**Notes**

Base image is `arm64v8/alpine:3.19` with `bash curl git openjdk21-jre python3 py3-pip cargo` added. This is a placeholder — swapped for a custom embedded Linux rootfs in a later iteration without changing anything else in the stack.

---

#### F-09 · Buildbarn storage & scheduler · 5 pts

**Tasks introduced**
- `task buildbarn:install-storage`
- `task buildbarn:install-scheduler`
- `task buildbarn:wait`

**Acceptance tests**
- `task buildbarn:test-scheduler` — `grpc_health_probe -addr=bb-scheduler:8980` returns `SERVING`
- `bb-storage` CAS endpoint responds to `FindMissingBlobs` RPC

---

#### F-10 · Buildbarn workers (Firecracker) · 5 pts

**Tasks introduced**
- `task buildbarn:install-workers`
- `task buildbarn:scale-workers`

**Acceptance tests**
- `task buildbarn:test-rbe` — `bazel build //examples:hello_world --remote_executor=grpc://bb-scheduler:8980` exits `0`
- `bb-scheduler` metrics show at least 1 worker connected

---

### Milestone 5 — CI integration

---

#### F-11 · GHA self-hosted runner in K3s · 5 pts

**Tasks introduced**
- `task actions:install-controller`
- `task actions:register-runner`
- `task actions:status`

**Acceptance tests**
- `task actions:test` — dummy workflow dispatched via `gh workflow run` completes within 3 minutes
- Runner pod in `actions-runner` namespace shows `Ready`

---

#### F-12 · Matrix build across repos · 5 pts

**Tasks introduced**
- `task test:matrix-smoke`
- `task test:collect-results`

**Acceptance tests**
- `task test:test-matrix` — GHA matrix workflow across 3 fixture repos all pass; one intentionally broken repo does not cancel the others (`fail-fast: false` confirmed)
- Bazel remote cache hit rate > 50% on second run (Nexus CAS working)

---

### Milestone 6 — Hardening

---

#### F-13 · Resource limits & PVC backup · 5 pts

**Tasks introduced**
- `task storage:set-limits`
- `task storage:backup-nexus`
- `task storage:restore-nexus`

**Acceptance tests**
- `task storage:test-limits` — all pods have `requests` and `limits` set; no pod in `BestEffort` QoS class
- `task storage:test-backup` — backup Job creates tarball on host path; restore Job recovers data and Nexus serves assets correctly after restore

---

#### F-14 · Full smoke suite in CI · 5 pts

**Tasks introduced**
- `task test:smoke`
- `task test:report`

**Acceptance tests**
- `task test:smoke` exits `0` end-to-end: K3s healthy → Nexus healthy → RBE healthy → sample build passes → cache hit on re-run
- Report written to `test-results/smoke.json` with all checks documented and timestamped

---

## 5. Full task execution order

`task up` runs this sequence. Each step waits for the previous to reach healthy before continuing.

```
 0  task tools:install-npm
 0  task tools:install-claude            (needs: tools:install-npm)
 1  task k3s:install
 2  task storage:setup                   (needs: k3s:install)
 3  task postgres:install                (needs: storage:setup)
 4  task postgres:wait
 5  task nexus:install                   (needs: postgres:wait)
 6  task nexus:wait
 7  task nexus:configure                 (needs: nexus:wait)
 8  task deps:collect                    (needs: nexus:configure)
 9  task deps:seed                       (needs: deps:collect)
10  task images:build-worker             (needs: nexus:configure)
11  task images:push-worker              (needs: images:build-worker)
12  task buildbarn:install-storage       (needs: nexus:configure)
13  task buildbarn:install-scheduler     (needs: buildbarn:install-storage)
14  task buildbarn:install-workers       (needs: buildbarn:install-scheduler + images:push-worker)
15  task actions:install-controller      (needs: k3s:install)
16  task actions:register-runner         (needs: actions:install-controller)
17  task test:smoke                      (needs: all above)
```

---

## 6. Key decisions & rationale

| Decision | Choice | Rationale |
|---|---|---|
| Kubernetes distro | K3s | Minimal footprint, ships containerd, single-binary install, Helm compatible |
| Nexus chart | `sonatype/nxrm-ha` | The legacy `nexus-repository-manager` chart is deprecated |
| Nexus database | External PostgreSQL | Embedded DB known to corrupt on K8s; Sonatype strongly recommends external Postgres |
| Build workers | Firecracker µVMs via `firecracker-containerd` | Sub-125ms cold start, full VM isolation per build, native ARM64 KVM |
| Initial worker rootfs | `arm64v8/alpine:3.19` | Fastest path to a working rootfs; replaced with custom image later |
| Cross-repo fan-out | GHA matrix (`fail-fast: false`) | Sufficient for static 30-repo list; Temporal not needed unless builds exceed 6h or list becomes dynamic |
| Dep cache warming | Taskfile K3s Job | Single-shot warm is simple; Temporal only justified by resumable progress or scheduling |
| Secrets | SOPS + age → `.env` | Existing setup; sourced by Taskfile `dotenv` directive |
| Dep list format | Per-ecosystem lockfiles (`maven.txt`, `pip.txt`, `cargo.txt`, `npm.txt`) | Lockfiles carry exact versions and hashes — more reliable for cache warming than SBOM |
| Namespaces | Per-component (`nexus`, `postgres`, `buildbarn`, `actions-runner`) | Clean RBAC, easy to tear down one component independently |
