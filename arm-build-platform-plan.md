# ARM Build Platform — Project Plan

> Single Mac Mini · K3s · nginx cache proxy · Buildbarn · GitHub Actions · ARM64

---

## 1. Architecture overview

The platform runs entirely on a single Apple Silicon Mac Mini. K3s hosts all persistent services as Helm-managed pods. Build isolation is provided by Firecracker micro-VMs (ARM64) launched on demand as K3s Jobs. GitHub Actions drives CI via a self-hosted runner; an nginx reverse-proxy cache serves as the unified package mirror for PyPI, Cargo, and Bazel BCR; a lightweight OCI registry (`registry:2`) stores worker images; Buildbarn provides Remote Build Execution (RBE) over the REAPI protocol so Bazel submits hundreds of actions in parallel without any custom orchestration layer.

### 1.1 Component summary

| Layer | Component | Role |
|---|---|---|
| Hardware | Apple Silicon Mac Mini | Single ARM64 host — all workloads run here |
| Hypervisor | Virtualization.framework / KVM shim | Provides `/dev/kvm` for Firecracker µVMs |
| Orchestration | K3s (single-node) | Kubernetes control plane + containerd runtime |
| Package cache | nginx reverse-proxy | PyPI, Cargo sparse index, Bazel BCR — transparent pass-through cache |
| Image registry | `registry:2` | OCI registry for ARM64 worker images |
| Remote execution | Buildbarn (scheduler + storage + workers) | REAPI server; Bazel submits actions, workers run in µVMs |
| Build workers | Firecracker µVMs — Alpine ARM64 (initial) | Isolated per-build VMs; swapped for custom rootfs later |
| CI trigger | GitHub Actions + self-hosted runner | Matrix strategy fans out across 30 repos |
| Dep warming | `task deps:collect` + `task deps:seed` | Scrapes lockfiles, warms nginx caches via K3s Job |
| Secrets | SOPS + age → `.env` | All credentials injected via `.env`; nothing committed |

### 1.2 Data flow

```
developer push (any of 30 repos)
  → GitHub Actions matrix (fail-fast: false, one leg per repo)
    → self-hosted runner pod (actions-runner-controller)
      → bazel test //... --remote_executor=grpc://bb-scheduler:8980
        → Buildbarn scheduler fans actions to Firecracker workers
          → each worker pulls rootfs from registry:2 (OCI registry)
          → pip deps resolved from nginx PyPI proxy cache
          → cargo deps resolved from nginx Cargo sparse cache
          → Bazel BCR modules resolved from nginx BCR proxy cache
          → results stream back to Bazel via REAPI WaitExecution
        → GHA reports pass/fail per matrix leg
```

### 1.3 Taskfile structure

```
Taskfile.yml              # root — includes all modules, defines `up` and `down`
tasks/
  k3s.yml                 # install, configure, uninstall K3s
  storage.yml             # namespaces + verify local-path PVC provisioner
  proxy.yml               # nginx reverse-proxy cache (PyPI, Cargo, Bazel BCR)
  registry.yml            # registry:2 OCI image registry
  deps.yml                # collect (scrape lockfiles) + seed (warm caches)
  buildbarn.yml           # bb-storage, bb-scheduler, bb-worker install
  images.yml              # build Alpine ARM64 worker image, push to registry:2
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
REGISTRY_PORT            # port for registry:2 OCI registry (e.g. 5000)
BB_SCHEDULER_ADDR
GITHUB_ORG
RUNNER_TOKEN
SOPS_AGE_KEY_FILE        # path to age private key
```

---

## 3. Milestone map

| Milestone | Features | Deliverable |
|---|---|---|
| M1 — Foundation | F-00 F-01 F-02 | Claude Code installed, K3s running, namespaces ready |
| M2 — Cache layer | F-03 F-04 | nginx package proxy live, OCI registry live |
| M3 — Dep warming | F-05 F-06 | Central dep list generated, caches warm for all ecosystems |
| M4 — Build execution | F-07 F-08 F-09 | Worker image in registry, Buildbarn RBE accepting Bazel actions |
| M5 — CI integration | F-10 F-11 | GHA runner in K3s, matrix build across sample repos passing |
| M6 — Hardening | F-12 F-13 | Resource limits, PVC backup, full smoke suite in CI |

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
- All 4 namespaces exist: `proxy`, `registry`, `buildbarn`, `actions-runner`

**Notes**

Originally 5 namespaces including `nexus` and `postgres`. Simplified to 4 — PostgreSQL and Nexus replaced by lighter services.

---

### Milestone 2 — Cache layer

---

#### ~~F-03 · nginx package proxy · 5 pts~~ ✓ DONE

**Tasks introduced**
- `task proxy:install`
- `task proxy:wait`
- `task proxy:uninstall`

**Acceptance tests**
- `task proxy:test` — all three upstream checks pass:
  - `curl http://proxy-svc/pypi/simple/pip/` returns HTML from PyPI
  - `curl http://proxy-svc/cargo/` returns Cargo sparse index response
  - `curl http://proxy-svc/bcr/` returns Bazel BCR response
- nginx cache dir PVC is bound and survives pod restart with cached data intact

**Notes**

Single nginx Deployment in the `proxy` namespace. One ConfigMap drives all three proxy upstreams:
- `/pypi/` → `https://pypi.org/` with `proxy_cache`
- `/cargo/` → `https://static.crates.io/` and `https://index.crates.io/` with `proxy_cache`
- `/bcr/` → `https://raw.githubusercontent.com/bazelbuild/bazel-central-registry/` with `proxy_cache`

PVC (local-path, 20Gi) holds the nginx cache. No auth, no user management, no database.

---

#### ~~F-04 · OCI image registry · 5 pts~~ ✓ DONE

**Tasks introduced**
- `task registry:install`
- `task registry:wait`
- `task registry:uninstall`

**Acceptance tests**
- `task registry:test` — `curl http://registry-svc:$REGISTRY_PORT/v2/` returns `{}`
- Push a test image from the Lima VM, pull it back, verify digest matches

**Notes**

`registry:2` Deployment in the `registry` namespace. PVC (local-path, 20Gi) for blob storage. Exposed via NodePort at `$REGISTRY_PORT` so Lima VM containerd and Firecracker workers can reach it without a port-forward.

---

### Milestone 3 — Dependency warming

---

#### ~~F-05 · Central dep list generation · 5 pts~~ ✓ DONE

**Tasks introduced**
- `task deps:collect`
- `task deps:diff`
- `task deps:commit`

**Acceptance tests**
- `task deps:test-collect` — `deps/pip.txt`, `deps/cargo.txt`, `deps/bazel-modules.txt` all non-empty after running against repo fixtures
- No duplicate coordinates in any file (dedup assertion)

**Notes**

`deps:collect` clones/pulls each of the 30 repos (or reads from local paths), extracts coordinates from ecosystem lockfiles (`requirements.lock`, `Cargo.lock`, `MODULE.bazel.lock`), deduplicates, and writes three files. Maven dropped — not used by any target repo.

---

#### ~~F-06 · Cache warming · 5 pts~~ ✓ DONE

**Tasks introduced**
- `task deps:seed`
- `task deps:verify-cache`

**Acceptance tests**
- `task deps:test-seed` — K3s Job exits `0`; spot-check 5 random deps from each ecosystem resolve through the nginx proxy (cache HIT on second request)
- nginx access log shows `HIT` for seeded entries

**Notes**

`deps:seed` launches a K3s Job (ARM64) that runs `pip download`, `cargo fetch`, and a Bazel module prefetch all pointed at the nginx proxy URLs. nginx `proxy_cache` automatically stores responses. A second pass confirms `X-Cache-Status: HIT`. No Temporal — a single Job is sufficient for a one-shot warm.

---

### Milestone 4 — Build execution

---

#### F-07 · Alpine ARM64 worker image · 5 pts

**Tasks introduced**
- `task images:build-worker`
- `task images:push-worker`
- `task images:list`

**Acceptance tests**
- `task images:test` — `docker pull registry.local:$REGISTRY_PORT/build-worker:alpine-arm64` exits `0`
- `uname -m` inside the pulled image returns `aarch64`

**Notes**

Base image is `arm64v8/alpine:3.19` with `bash curl git openjdk21-jre python3 py3-pip cargo` added. Pushed to the `registry:2` instance from F-04. This is a placeholder — swapped for a custom embedded Linux rootfs in a later iteration without changing anything else in the stack.

---

#### F-08 · Buildbarn storage & scheduler · 5 pts

**Tasks introduced**
- `task buildbarn:install-storage`
- `task buildbarn:install-scheduler`
- `task buildbarn:wait`

**Acceptance tests**
- `task buildbarn:test-scheduler` — `grpc_health_probe -addr=bb-scheduler:8980` returns `SERVING`
- `bb-storage` CAS endpoint responds to `FindMissingBlobs` RPC

---

#### F-09 · Buildbarn workers (Firecracker) · 5 pts

**Tasks introduced**
- `task buildbarn:install-workers`
- `task buildbarn:scale-workers`

**Acceptance tests**
- `task buildbarn:test-rbe` — `bazel build //examples:hello_world --remote_executor=grpc://bb-scheduler:8980` exits `0`
- `bb-scheduler` metrics show at least 1 worker connected

---

### Milestone 5 — CI integration

---

#### F-10 · GHA self-hosted runner in K3s · 5 pts

**Tasks introduced**
- `task actions:install-controller`
- `task actions:register-runner`
- `task actions:status`

**Acceptance tests**
- `task actions:test` — dummy workflow dispatched via `gh workflow run` completes within 3 minutes
- Runner pod in `actions-runner` namespace shows `Ready`

---

#### F-11 · Matrix build across repos · 5 pts

**Tasks introduced**
- `task test:matrix-smoke`
- `task test:collect-results`

**Acceptance tests**
- `task test:test-matrix` — GHA matrix workflow across 3 fixture repos all pass; one intentionally broken repo does not cancel the others (`fail-fast: false` confirmed)
- Bazel remote cache hit rate > 50% on second run (Buildbarn CAS working)

---

### Milestone 6 — Hardening

---

#### F-12 · Resource limits & PVC backup · 5 pts

**Tasks introduced**
- `task storage:set-limits`
- `task storage:backup-proxy`
- `task storage:restore-proxy`

**Acceptance tests**
- `task storage:test-limits` — all pods have `requests` and `limits` set; no pod in `BestEffort` QoS class
- `task storage:test-backup` — backup Job creates tarball on host path; restore Job recovers data and proxy serves cached assets correctly after restore

---

#### F-13 · Full smoke suite in CI · 5 pts

**Tasks introduced**
- `task test:smoke`
- `task test:report`

**Acceptance tests**
- `task test:smoke` exits `0` end-to-end: K3s healthy → proxy healthy → registry healthy → RBE healthy → sample build passes → cache hit on re-run
- Report written to `test-results/smoke.json` with all checks documented and timestamped

---

## 5. Full task execution order

`task up` runs this sequence. Each step waits for the previous to reach healthy before continuing.

```
 0  task tools:install-npm
 0  task tools:install-claude            (needs: tools:install-npm)
 1  task k3s:install
 2  task storage:setup                   (needs: k3s:install)
 3  task proxy:install                   (needs: storage:setup)
 4  task proxy:wait
 5  task registry:install                (needs: storage:setup)
 6  task registry:wait
 7  task deps:collect                    (needs: proxy:wait)
 8  task deps:seed                       (needs: deps:collect)
 9  task images:build-worker             (needs: registry:wait)
10  task images:push-worker              (needs: images:build-worker)
11  task buildbarn:install-storage       (needs: storage:setup)
12  task buildbarn:install-scheduler     (needs: buildbarn:install-storage)
13  task buildbarn:install-workers       (needs: buildbarn:install-scheduler + images:push-worker)
14  task actions:install-controller      (needs: k3s:install)
15  task actions:register-runner         (needs: actions:install-controller)
16  task test:smoke                      (needs: all above)
```

---

## 6. Key decisions & rationale

| Decision | Choice | Rationale |
|---|---|---|
| Kubernetes distro | K3s | Minimal footprint, ships containerd, single-binary install, Helm compatible |
| Package cache | nginx `proxy_cache` | Zero auth/DB overhead; transparent pass-through; single binary; PVC-backed cache survives restarts |
| Image registry | `registry:2` | ~25MB image; OCI-compliant; no auth needed for internal-only use |
| Nexus / PostgreSQL | Dropped | nxrm-ha chart v90.x requires Pro license; Postgres was only needed as Nexus backing store |
| Ecosystems cached | PyPI, Cargo, Bazel BCR | Maven dropped — not used by any target repo |
| Build workers | Firecracker µVMs via `firecracker-containerd` | Sub-125ms cold start, full VM isolation per build, native ARM64 KVM |
| Initial worker rootfs | `arm64v8/alpine:3.19` | Fastest path to a working rootfs; replaced with custom image later |
| Cross-repo fan-out | GHA matrix (`fail-fast: false`) | Sufficient for static 30-repo list; Temporal not needed unless builds exceed 6h or list becomes dynamic |
| Dep cache warming | Taskfile K3s Job | Single-shot warm is simple; Temporal only justified by resumable progress or scheduling |
| Secrets | SOPS + age → `.env` | Existing setup; sourced by Taskfile `dotenv` directive |
| Dep list format | Per-ecosystem lockfiles (`pip.txt`, `cargo.txt`, `bazel-modules.txt`) | Lockfiles carry exact versions — more reliable for cache warming than SBOM |
| Namespaces | Per-component (`proxy`, `registry`, `buildbarn`, `actions-runner`) | Clean RBAC, easy to tear down one component independently |
