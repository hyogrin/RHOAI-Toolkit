# RHAII (Red Hat AI Inference) Version Map & Fast Build Guide

## Registry Namespace Evolution

| RHOAI Version | GA Image Namespace | EA/Fast Image Namespace |
|---|---|---|
| 3.0 – 3.3 | `registry.redhat.io/rhaiis/` | — |
| 3.4 – 3.5 | `registry.redhat.io/rhaii/` | `registry.redhat.io/rhaii-early-access/` |
| 3.6+ | TBD | `registry.redhat.io/rhai-early-access/` |

## vLLM Version Mapping

| RHAII Tag | vLLM Version | Release Type | PyPI Index Path |
|---|---|---|---|
| 3.4.0 | 0.18.0 | GA | `rhoai/3.4/cuda12.8-ubi9/simple/` |
| 3.5.0-ea.1 | 0.19.1 | Early Access | `rhoai/3.5-EA1/cuda12.8-ubi9/simple/` |
| 3.5.0-ea.2 | 0.21.0 | Early Access | `rhoai/3.5-EA2/cuda12.8-ubi9/simple/` |
| 3.5.0 | 0.24.0+rhaiv.9 | GA | `rhoai/3.5/cuda12.8-ubi9/simple/` |
| 3.5.1 | 0.24.x (patch) | GA Patch | — |
| **3.6.0-ea.1** | **0.26.0+rhaiv.5** | **Early Access** | `rhoai/3.6-EA1/cuda12.9-ubi9/simple/` |

> **Note**: vLLM 0.29 does NOT exist upstream (latest: v0.25.1 as of 2026-07-14).
> RHAII packages include Red Hat patches indicated by `+rhaiv.N` suffix.

## RHAI 3.6.0-ea.1 Base Image Details

Verified by running `registry.redhat.io/rhai-early-access/base-image-cuda-12.9-rhel9:3.6.0-ea.1` on cluster:

| Component | Version |
|---|---|
| OS | RHEL 9.8 (Plow) |
| Python | 3.12.14 |
| CUDA | 12.9, V12.9.86 (2025-05-27) |
| vLLM (pre-installed) | ❌ Not installed (base image only) |
| vLLM (available via pip) | 0.26.0+rhaiv.5, 0.26.0+rhaiv.1, 0.24.0+rhaiv.9 |
| PyPI Index URL | `https://packages.redhat.com/api/pypi/public-rhai/rhoai/3.6-EA1/cuda12.9-ubi9/simple/` |

## Image Names (3.6.0-ea.1)

| Image | Status | Purpose |
|---|---|---|
| `rhai-early-access/base-image-cuda-12.9-rhel9:3.6.0-ea.1` | ✅ Available | Base image (Python + CUDA, no vLLM) |
| `rhai-early-access/vllm-cuda-rhel9:3.6.0-ea.1` | 🔒 Unauthorized | vLLM serving image (not yet published) |

## How to Pull RHAI Early Access Images

### Prerequisites

1. **Red Hat account** with active subscription
2. **Registry authentication**: Login to `registry.redhat.io`

### Step 1: Authenticate

```bash
# On your workstation
podman login registry.redhat.io
# Enter Red Hat credentials

# On OpenShift cluster - create pull secret
oc create secret docker-registry rhai-pull-secret \
  --docker-server=registry.redhat.io \
  --docker-username=<RH_USERNAME> \
  --docker-password=<RH_PASSWORD> \
  -n <namespace>

# Or use the cluster's existing pull secret (if already configured)
```

### Step 2: Inspect Image (optional)

```bash
# From macOS ARM (must override arch):
skopeo inspect \
  --override-arch amd64 --override-os linux \
  docker://registry.redhat.io/rhai-early-access/base-image-cuda-12.9-rhel9:3.6.0-ea.1

# From Linux x86_64:
skopeo inspect \
  docker://registry.redhat.io/rhai-early-access/base-image-cuda-12.9-rhel9:3.6.0-ea.1
```

### Step 3: Pull and Run on Cluster

```bash
# Run a test pod to inspect image contents
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: rhai-36-ea1-check
  namespace: demo
spec:
  restartPolicy: Never
  containers:
  - name: check
    image: registry.redhat.io/rhai-early-access/base-image-cuda-12.9-rhel9:3.6.0-ea.1
    command: ["/bin/bash", "-c"]
    args:
    - |
      echo "=== OS ==="
      cat /etc/redhat-release
      echo "=== Python ==="
      python3 --version
      echo "=== CUDA ==="
      nvcc --version 2>/dev/null | head -5
      echo "=== PyPI Index ==="
      pip config list
      echo "=== Available vLLM ==="
      pip index versions vllm 2>/dev/null | head -5
      echo "=== DONE ==="
      sleep 300
EOF

# Wait for pod to start
oc wait --for=condition=Ready pod/rhai-36-ea1-check -n demo --timeout=300s

# Check output
oc logs rhai-36-ea1-check -n demo

# Cleanup
oc delete pod rhai-36-ea1-check -n demo
```

### Step 4: Install vLLM from Index (inside container)

The base image is pre-configured with Red Hat's private PyPI index. Inside the container:

```bash
# vLLM will be pulled from Red Hat's index automatically
pip install vllm
# → installs vllm 0.26.0+rhaiv.5

# Or pin a specific version
pip install vllm==0.26.0+rhaiv.5
```

## Fast Build Visibility in Dashboard

> **Important**: Pulling the image alone does NOT make it appear in the RHOAI Dashboard.

### How Fast Builds Appear in Dashboard

1. **RHOAI operator update** delivers pre-installed `ServingRuntime` templates with:
   - `opendatahub.io/fast-version: "N"` annotation (e.g., "1")
   - `opendatahub.io/support-status: unsupported` annotation (hidden by default)

2. **Admin enables** in Dashboard:
   - Settings → Model resources and operations → Serving runtimes
   - Toggle the fast runtime → Accept risk dialog → Enable
   - Adds `opendatahub.io/unsupported-status-accepted: "true"` annotation

3. **Data scientist** can now see and select the fast runtime in model deployment wizard

### Badge System

| Badge | Color | Meaning |
|---|---|---|
| Pre-installed | Blue | Red Hat-provided (GA or fast) |
| Limited support | Orange | 1-month support; admin accepted risk |
| fast-N | Yellow | Fast build iteration number |
| Version (e.g., 0.26.0) | Blue | Upstream vLLM version |

### GitOps Alternative

```yaml
# Add both annotations to enable without Dashboard interaction:
metadata:
  annotations:
    opendatahub.io/support-status: unsupported
    opendatahub.io/unsupported-status-accepted: "true"
```

### Using Fast Image as Custom Runtime (without operator)

If the operator hasn't delivered the template yet, create a custom `ServingRuntime`:

```yaml
apiVersion: serving.kserve.io/v1alpha1
kind: ServingRuntime
metadata:
  annotations:
    opendatahub.io/recommended-accelerators: '["nvidia.com/gpu"]'
    openshift.io/display-name: "vLLM RHAI 3.6 EA1 (Custom)"
  labels:
    opendatahub.io/dashboard: "true"
  name: vllm-rhai-36-ea1
spec:
  annotations:
    prometheus.io/port: "8080"
    prometheus.io/path: /metrics
  multiModel: false
  supportedModelFormats:
  - autoSelect: true
    name: vLLM
  containers:
  - name: kserve-container
    image: registry.redhat.io/rhai-early-access/vllm-cuda-rhel9:3.6.0-ea.1
    ports:
    - containerPort: 8080
      protocol: TCP
```

> ⚠️ Custom runtimes show NO "Pre-installed" badge and have NO Red Hat support.

## Red Hat PyPI Index Structure

```
https://packages.redhat.com/api/pypi/public-rhai/rhoai/{VERSION}/{VARIANT}/simple/
```

| Parameter | Examples |
|---|---|
| VERSION | `3.5`, `3.5-EA1`, `3.5-EA2`, `3.6-EA1` |
| VARIANT | `cuda12.8-ubi9`, `cuda12.9-ubi9` |

Check available versions:

```bash
curl -s "https://packages.redhat.com/api/pypi/public-rhai/rhoai/3.6-EA1/cuda12.9-ubi9/simple/vllm/" | \
  grep -oE 'vllm-[0-9]+\.[0-9]+\.[0-9]+[^"]*\.whl'
```

---

*Last verified: 2026-09-13 on RHOAI 3.5.0 cluster*
