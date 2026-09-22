#!/bin/bash
################################################################################
# Deploy AutoRAG Demo (RHOAI 3.5)
################################################################################
# Sets up infrastructure for AutoRAG (Technology Preview):
#   - MinIO for document storage and pipeline artifacts
#   - Milvus vector database (remote — required by AutoRAG)
#   - Pipeline Server (DSPA) for Kubeflow Pipelines
#   - S3 data connection and sample documents
#   - OGX Server (replaces LlamaStack in RHOAI 3.5)
#
# AutoRAG itself is a dashboard-native feature — after infrastructure is ready,
# use the RHOAI dashboard: Develop and train > AutoRAG
#
# Prerequisites:
#   - OGX component activated (ogx: Managed in DSC) — RHOAI 3.5
#     OR Llama Stack Operator activated (llamastackoperator: Managed) — RHOAI 3.4
#   - OGX/LlamaStack instance with foundation + embedding models
#   - Gen AI Studio enabled in dashboard
#
# Usage:
#   ./deploy.sh                    # Deploy to autorag-demo namespace
#   ./deploy.sh -n my-namespace    # Custom namespace
#   ./deploy.sh --delete           # Remove deployment
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$ROOT_DIR/lib/utils/colors.sh"
source "$ROOT_DIR/lib/utils/common.sh"
source "$ROOT_DIR/lib/functions/notebook-env.sh"

NAMESPACE="${1:-autorag-demo}"
DELETE_MODE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--namespace) NAMESPACE="$2"; shift 2 ;;
        --delete) DELETE_MODE=true; shift ;;
        -h|--help)
            echo "Usage: $0 [-n namespace] [--delete]"
            exit 0
            ;;
        *) shift ;;
    esac
done

################################################################################
# Detect RHOAI version: OGX (3.5+) vs LlamaStack (3.4)
################################################################################
detect_ogx_or_llamastack() {
    local ogx_state llamastack_state

    ogx_state=$(oc get datasciencecluster default-dsc \
        -o jsonpath='{.spec.components.ogx.managementState}' 2>/dev/null || echo "")
    llamastack_state=$(oc get datasciencecluster default-dsc \
        -o jsonpath='{.spec.components.llamastackoperator.managementState}' 2>/dev/null || echo "")

    if [ "$ogx_state" = "Managed" ]; then
        USE_OGX=true
        print_info "Detected RHOAI 3.5+ (OGX component: Managed)"
    elif [ "$llamastack_state" = "Managed" ]; then
        USE_OGX=false
        print_info "Detected RHOAI 3.4 (LlamaStack Operator: Managed)"
    else
        # Default to OGX for fresh installs
        USE_OGX=true
        print_warning "Neither OGX nor LlamaStack is Managed in DSC"
        print_info "Defaulting to OGX (RHOAI 3.5). Activating OGX in DSC..."
        oc patch datasciencecluster default-dsc --type=merge \
            -p '{"spec":{"components":{"ogx":{"managementState":"Managed"},"llamastackoperator":{"managementState":"Removed"}}}}' 2>/dev/null || \
            print_warning "Could not patch DSC — enable ogx manually"
    fi
}

print_header "AutoRAG Demo (Technology Preview)"

if [ "$DELETE_MODE" = true ]; then
    print_step "Removing AutoRAG infrastructure from $NAMESPACE..."
    # Try OGX resources first, then LlamaStack (backwards compat)
    oc delete ogxserver autorag-ogx -n "$NAMESPACE" --ignore-not-found 2>/dev/null
    oc delete llamastackdistribution autorag-llamastack -n "$NAMESPACE" --ignore-not-found 2>/dev/null
    export NAMESPACE
    # OGX PostgreSQL
    envsubst < "$SCRIPT_DIR/manifests/ogx-postgresql.yaml" | oc delete -f - --ignore-not-found 2>/dev/null
    # Legacy LlamaStack PostgreSQL
    if [ -f "$SCRIPT_DIR/manifests/llamastack-postgresql.yaml" ]; then
        envsubst < "$SCRIPT_DIR/manifests/llamastack-postgresql.yaml" | oc delete -f - --ignore-not-found 2>/dev/null
    fi
    oc delete configmap autorag-ogx-config -n "$NAMESPACE" --ignore-not-found 2>/dev/null
    oc delete secret ogx-server-secret llama-stack-secret milvus-connection-secret -n "$NAMESPACE" --ignore-not-found 2>/dev/null
    oc delete datasciencepipelineapplication pipelines-definition -n "$NAMESPACE" --ignore-not-found 2>/dev/null
    envsubst < "$SCRIPT_DIR/manifests/milvus.yaml" | oc delete -f - --ignore-not-found 2>/dev/null
    envsubst < "$SCRIPT_DIR/manifests/minio.yaml" | oc delete -f - --ignore-not-found 2>/dev/null
    print_success "AutoRAG infrastructure removed from $NAMESPACE"
    exit 0
fi

if ! oc whoami &>/dev/null; then
    print_error "Not logged in to OpenShift. Run: oc login <cluster-url>"
    exit 1
fi

# --- Step 0: Verify prerequisites ---
print_step "Checking prerequisites..."

detect_ogx_or_llamastack

# Check AI Pipelines
if ! oc get crd datasciencepipelinesapplications.datasciencepipelinesapplications.opendatahub.io &>/dev/null 2>&1; then
    print_error "DSPA CRD not found. Ensure 'aipipelines: Managed' in your DataScienceCluster."
    exit 1
fi

ensure_namespace "$NAMESPACE"
oc label namespace "$NAMESPACE" opendatahub.io/dashboard=true --overwrite 2>/dev/null || true

# Enable AutoRAG in dashboard
oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications \
    --type=merge -p '{"spec":{"dashboardConfig":{"autorag":true}}}' 2>/dev/null || true

# --- Step 1: MinIO for document storage + pipeline artifacts ---
print_step "Deploying MinIO for document storage..."
if oc get deployment minio -n "$NAMESPACE" &>/dev/null; then
    print_info "MinIO already deployed in $NAMESPACE"
else
    export NAMESPACE
    envsubst < "$SCRIPT_DIR/manifests/minio.yaml" | oc apply -f -
    oc rollout status deployment/minio -n "$NAMESPACE" --timeout=120s 2>/dev/null || true
fi

# Create buckets and upload sample docs
print_step "Creating S3 buckets and uploading sample documents..."
MINIO_POD=$(oc get pod -l app=minio -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$MINIO_POD" ]; then
    oc exec "$MINIO_POD" -n "$NAMESPACE" -- sh -c '
        mc alias set local http://localhost:9000 ${MINIO_ROOT_USER} ${MINIO_ROOT_PASSWORD} 2>/dev/null
        mc mb --ignore-existing local/pipeline-artifacts 2>/dev/null
        mc mb --ignore-existing local/autorag-docs 2>/dev/null
    ' 2>/dev/null || print_warning "Could not create buckets — MinIO may still be starting"

    for doc in "$SCRIPT_DIR/sample-data/docs"/*; do
        if [ -f "$doc" ]; then
            BASENAME=$(basename "$doc")
            oc exec -i "$MINIO_POD" -n "$NAMESPACE" -- sh -c "cat > /tmp/$BASENAME" \
                < "$doc" 2>/dev/null
            oc exec "$MINIO_POD" -n "$NAMESPACE" -- sh -c \
                "mc cp /tmp/$BASENAME local/autorag-docs/$BASENAME 2>/dev/null" 2>/dev/null || true
        fi
    done

    # Upload test data for AutoRAG evaluation
    if [ -f "$SCRIPT_DIR/sample-data/test-data.json" ]; then
        oc exec -i "$MINIO_POD" -n "$NAMESPACE" -- sh -c "cat > /tmp/test-data.json" \
            < "$SCRIPT_DIR/sample-data/test-data.json" 2>/dev/null
        oc exec "$MINIO_POD" -n "$NAMESPACE" -- sh -c \
            "mc cp /tmp/test-data.json local/autorag-docs/test-data.json 2>/dev/null" 2>/dev/null || true
    fi
    print_success "Sample documents and test data uploaded to s3://autorag-docs/"
else
    print_warning "MinIO pod not found yet — upload documents after MinIO is ready"
fi

# --- Step 2: S3 data connection ---
print_step "Creating S3 data connection for AutoRAG documents..."
oc apply -n "$NAMESPACE" -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: aws-connection-autorag-docs
  namespace: $NAMESPACE
  labels:
    opendatahub.io/dashboard: "true"
    opendatahub.io/managed: "true"
  annotations:
    opendatahub.io/connection-type: s3
    openshift.io/display-name: "AutoRAG Documents"
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: minio
  AWS_SECRET_ACCESS_KEY: minio123
  AWS_DEFAULT_REGION: us-east-1
  AWS_S3_BUCKET: autorag-docs
  AWS_S3_ENDPOINT: http://minio.${NAMESPACE}.svc.cluster.local:9000
EOF

# --- Step 3: Milvus vector database ---
print_step "Deploying Milvus vector database..."
if oc get deployment milvus-standalone -n "$NAMESPACE" &>/dev/null; then
    print_info "Milvus already deployed in $NAMESPACE"
else
    export NAMESPACE
    envsubst < "$SCRIPT_DIR/manifests/milvus.yaml" | oc apply -f -
    print_info "Milvus deploying (takes 1-2 minutes for readiness)..."
    oc rollout status deployment/milvus-standalone -n "$NAMESPACE" --timeout=180s 2>/dev/null || \
        print_warning "Milvus not ready yet — check: oc get pods -l app=milvus -n $NAMESPACE"
fi

MILVUS_HOST="milvus.${NAMESPACE}.svc.cluster.local"
MILVUS_PORT="19530"

# --- Step 4: Pipeline Server (DSPA) ---
print_step "Deploying Pipeline Server (DSPA)..."
if oc get datasciencepipelinesapplication pipelines-definition -n "$NAMESPACE" &>/dev/null 2>&1; then
    print_info "Pipeline server already exists in $NAMESPACE"
else
    export NAMESPACE
    envsubst < "$SCRIPT_DIR/manifests/pipeline-server.yaml" | oc apply -f -
    print_info "Pipeline server deploying (takes 1-2 minutes)..."
fi

# --- Step 5: PostgreSQL for OGX/LlamaStack metadata ---
if [ "$USE_OGX" = true ]; then
    print_step "Deploying PostgreSQL for OGX metadata store..."
    if oc get deployment ogx-postgres -n "$NAMESPACE" &>/dev/null; then
        print_info "OGX PostgreSQL already deployed in $NAMESPACE"
    else
        export NAMESPACE
        envsubst < "$SCRIPT_DIR/manifests/ogx-postgresql.yaml" | oc apply -f -
        oc rollout status deployment/ogx-postgres -n "$NAMESPACE" --timeout=120s 2>/dev/null || \
            print_warning "PostgreSQL not ready yet — check: oc get pods -l app=ogx-postgres -n $NAMESPACE"
    fi
else
    print_step "Deploying PostgreSQL for LlamaStack metadata store..."
    if oc get deployment llamastack-postgres -n "$NAMESPACE" &>/dev/null; then
        print_info "LlamaStack PostgreSQL already deployed in $NAMESPACE"
    else
        export NAMESPACE
        envsubst < "$SCRIPT_DIR/manifests/llamastack-postgresql.yaml" | oc apply -f -
        oc rollout status deployment/llamastack-postgres -n "$NAMESPACE" --timeout=120s 2>/dev/null || \
            print_warning "PostgreSQL not ready yet — check: oc get pods -l app=llamastack-postgres -n $NAMESPACE"
    fi
fi

# --- Step 6: OGX Server / LlamaStack ---
if [ "$USE_OGX" = true ]; then
    print_step "Deploying OGX Server (RHOAI 3.5)..."
else
    print_step "Deploying LlamaStack (RHOAI 3.4)..."
fi

# Detect LLM endpoint — try standard InferenceService first, then LLMInferenceService
if detect_direct_llm_endpoint; then
    print_info "Found direct vLLM LLM: $DIRECT_MODEL_NAME (ns: $DIRECT_MODEL_NS)"
    print_info "  → $DIRECT_BASE_URL"
else
    # Fallback: detect LLMInferenceService (MaaS) and use its workload service directly
    print_info "No standard InferenceService LLM found — checking LLMInferenceService..."
    LLMISVC_NAME="" LLMISVC_NS=""
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        LLMISVC_NS=$(echo "$line" | awk '{print $1}')
        LLMISVC_NAME=$(echo "$line" | awk '{print $2}')
        break
    done < <(oc get llminferenceservice -A --no-headers 2>/dev/null || true)

    if [ -n "$LLMISVC_NAME" ]; then
        # LLMInferenceService creates a workload service: <name>-kserve-workload-svc:8000
        WORKLOAD_SVC="${LLMISVC_NAME}-kserve-workload-svc"
        WORKLOAD_PORT=$(oc get svc "$WORKLOAD_SVC" -n "$LLMISVC_NS" \
            -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "8000")
        if oc get svc "$WORKLOAD_SVC" -n "$LLMISVC_NS" &>/dev/null; then
            # Detect protocol from port name (KServe workload services use HTTPS)
            WORKLOAD_PORT_NAME=$(oc get svc "$WORKLOAD_SVC" -n "$LLMISVC_NS" \
                -o jsonpath='{.spec.ports[0].name}' 2>/dev/null || echo "http")
            WORKLOAD_PROTO="http"
            if echo "$WORKLOAD_PORT_NAME" | grep -qi "https"; then
                WORKLOAD_PROTO="https"
            fi
            DIRECT_MODEL_NAME="$LLMISVC_NAME"
            DIRECT_MODEL_NS="$LLMISVC_NS"
            DIRECT_BASE_URL="${WORKLOAD_PROTO}://${WORKLOAD_SVC}.${LLMISVC_NS}.svc:${WORKLOAD_PORT}/v1"
            print_info "Found LLMInferenceService: $LLMISVC_NAME (ns: $LLMISVC_NS)"
            print_info "  → Using workload service: $DIRECT_BASE_URL"
        else
            print_warning "LLMInferenceService $LLMISVC_NAME found but workload service not available"
        fi
    fi

    if [ -z "${DIRECT_MODEL_NAME:-}" ]; then
        print_warning "No LLM endpoint found — OGX/LlamaStack will need manual VLLM_URL configuration"
    fi
fi

# Detect embedding model — search this namespace first, then all namespaces
EMBEDDING_ISVC="" EMBEDDING_NS=""
# Search current namespace
while IFS= read -r isvc_name; do
    [ -z "$isvc_name" ] && continue
    if echo "$isvc_name" | grep -qi -E 'bge|e5-|embed|nomic-embed|gemma.*embed'; then
        EMBEDDING_ISVC="$isvc_name"
        EMBEDDING_NS="$NAMESPACE"
        break
    fi
done < <(oc get inferenceservice -n "$NAMESPACE" --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null || true)

# If not found locally, search cluster-wide
if [ -z "$EMBEDDING_ISVC" ]; then
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local_ns=$(echo "$line" | awk '{print $1}')
        local_name=$(echo "$line" | awk '{print $2}')
        if echo "$local_name" | grep -qi -E 'bge|e5-|embed|nomic-embed|gemma.*embed'; then
            EMBEDDING_ISVC="$local_name"
            EMBEDDING_NS="$local_ns"
            break
        fi
    done < <(oc get inferenceservice -A --no-headers 2>/dev/null || true)
fi

EMBED_SVC="" EMBED_PORT=""
if [ -n "$EMBEDDING_ISVC" ]; then
    EMBED_SVC=$(oc get svc -n "$EMBEDDING_NS" -l "serving.kserve.io/inferenceservice=${EMBEDDING_ISVC}" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    EMBED_SVC="${EMBED_SVC:-${EMBEDDING_ISVC}-predictor}"
    EMBED_PORT=$(oc get svc "$EMBED_SVC" -n "$EMBEDDING_NS" \
        -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "80")
    print_info "Found embedding model: $EMBEDDING_ISVC (ns: $EMBEDDING_NS)"
else
    print_warning "No embedding model found cluster-wide — deploy one (e.g. bge-m3) before running AutoRAG"
fi

# Resolve embedding auth token (InferenceService with enable-auth needs SA token + RBAC)
VLLM_EMBEDDING_API_TOKEN="fake"
if [ -n "$EMBEDDING_ISVC" ] && [ -n "$EMBEDDING_NS" ]; then
    local_auth=$(oc get inferenceservice "$EMBEDDING_ISVC" -n "$EMBEDDING_NS" \
        -o jsonpath='{.metadata.annotations.security\.opendatahub\.io/enable-auth}' 2>/dev/null || echo "")
    if [ "$local_auth" = "true" ]; then
        print_info "Embedding service has auth enabled — setting up SA token + RBAC..."
        SA_TOKEN=$(oc create token default -n "$NAMESPACE" --duration=87600h 2>/dev/null || echo "")
        if [ -n "$SA_TOKEN" ]; then
            VLLM_EMBEDDING_API_TOKEN="$SA_TOKEN"
            # Grant RBAC: SA needs 'get' on inferenceservices in the model namespace
            # (KServe auth proxy validates the bearer token against K8s RBAC)
            oc apply -f - <<RBAC_EOF 2>/dev/null || true
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: autorag-isvc-reader
  namespace: $EMBEDDING_NS
rules:
  - apiGroups: ["serving.kserve.io"]
    resources: ["inferenceservices"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: autorag-isvc-reader
  namespace: $EMBEDDING_NS
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: autorag-isvc-reader
subjects:
  - kind: ServiceAccount
    name: default
    namespace: $NAMESPACE
RBAC_EOF
            print_info "SA token + RBAC configured for embedding auth"
        else
            print_warning "Could not generate SA token — embedding may fail with Unauthorized"
        fi
    fi
fi

# Resolve LLM auth token (LLMInferenceService workload services also need SA token)
VLLM_API_TOKEN="fake"
if [ -n "${DIRECT_MODEL_NAME:-}" ] && [ -n "${DIRECT_MODEL_NS:-}" ] && [ "$DIRECT_MODEL_NS" != "$NAMESPACE" ]; then
    # Use the same SA token we already generated (or create one)
    if [ -z "${SA_TOKEN:-}" ]; then
        SA_TOKEN=$(oc create token default -n "$NAMESPACE" --duration=87600h 2>/dev/null || echo "")
    fi
    if [ -n "$SA_TOKEN" ]; then
        VLLM_API_TOKEN="$SA_TOKEN"
        # Grant RBAC for LLMInferenceService access
        oc apply -f - <<LLM_RBAC_EOF 2>/dev/null || true
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: autorag-llmisvc-reader
  namespace: $DIRECT_MODEL_NS
rules:
  - apiGroups: ["serving.kserve.io"]
    resources: ["inferenceservices", "llminferenceservices"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: autorag-llmisvc-reader
  namespace: $DIRECT_MODEL_NS
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: autorag-llmisvc-reader
subjects:
  - kind: ServiceAccount
    name: default
    namespace: $NAMESPACE
LLM_RBAC_EOF
        print_info "RBAC configured for LLM auth in namespace $DIRECT_MODEL_NS"
    fi
fi

# Set envsubst variables (shared between OGX and LlamaStack manifests)
export INFERENCE_MODEL="${DIRECT_MODEL_NAME:-}"
export VLLM_URL="${DIRECT_BASE_URL:-}"
export VLLM_TLS_VERIFY="false"
export VLLM_API_TOKEN
export EMBEDDING_MODEL="${EMBEDDING_ISVC:-bge-m3}"
export EMBEDDING_PROVIDER_MODEL_ID="${EMBEDDING_ISVC:-bge-m3}"
if [ -n "$EMBEDDING_ISVC" ]; then
    export VLLM_EMBEDDING_URL="https://${EMBED_SVC}.${EMBEDDING_NS}.svc.cluster.local:${EMBED_PORT}/v1"
else
    export VLLM_EMBEDDING_URL=""
fi
export VLLM_EMBEDDING_API_TOKEN
export VLLM_EMBEDDING_TLS_VERIFY="false"
export VLLM_EMBEDDING_MAX_TOKENS="8192"
# Milvus URI must include http:// protocol prefix (pymilvus requirement)
export MILVUS_URI="http://${MILVUS_HOST}:${MILVUS_PORT}"
export MILVUS_TOKEN=""

# Deploy the appropriate server
if [ "$USE_OGX" = true ]; then
    envsubst < "$SCRIPT_DIR/manifests/ogxserver.yaml" | oc apply -f -
    OGX_DEPLOY_NAME="autorag-ogx"
    SERVER_LABEL="OGX Server"
else
    envsubst < "$SCRIPT_DIR/manifests/llamastack.yaml" | oc apply -f -
    OGX_DEPLOY_NAME="autorag-llamastack"
    SERVER_LABEL="LlamaStack"
fi
print_info "$SERVER_LABEL deploying (takes 1-2 minutes)..."

# Wait briefly for pod to start
sleep 5
oc rollout status deployment/"$OGX_DEPLOY_NAME" -n "$NAMESPACE" --timeout=180s 2>/dev/null || \
    print_warning "$SERVER_LABEL not ready yet — check: oc get pods -n $NAMESPACE"

if [ "$USE_OGX" = true ]; then
    SERVER_URL="http://autorag-ogx-service.${NAMESPACE}.svc.cluster.local:8321"
else
    SERVER_URL="http://autorag-llamastack-service.${NAMESPACE}.svc.cluster.local:8321"
fi

echo ""
print_success "AutoRAG Demo infrastructure deployed"
print_info "Namespace: $NAMESPACE"
print_info "Milvus endpoint: $MILVUS_URI"
if [ -n "${DIRECT_MODEL_NAME:-}" ]; then
    print_info "LLM (direct vLLM): $DIRECT_MODEL_NAME → $VLLM_URL"
fi
if [ -n "${EMBEDDING_ISVC:-}" ]; then
    print_info "Embedding: $EMBEDDING_ISVC → $VLLM_EMBEDDING_URL"
fi
print_info "$SERVER_LABEL: $SERVER_URL"
echo ""
echo "  Remaining manual steps:"
echo ""
if [ "$USE_OGX" = true ]; then
    echo "  1. CREATE OGX CONNECTION IN PROJECT:"
    echo "     - Dashboard > $NAMESPACE > Connections"
    echo "     - Add connection: OGX Server"
    echo "       Base URL: $SERVER_URL"
    echo "       API Key: (leave empty or use any value)"
else
    echo "  1. CREATE LLAMA STACK CONNECTION IN PROJECT:"
    echo "     - Dashboard > $NAMESPACE > Connections"
    echo "     - Add connection: Llama Stack"
    echo "       Base URL: $SERVER_URL"
    echo "       API Key: (leave empty or use any value)"
fi
echo ""
echo "  2. RUN AUTORAG:"
echo "     - Dashboard > Develop and train > AutoRAG"
echo "     - Click 'Create run'"
echo "     - S3 Connection: 'AutoRAG Documents'"
if [ "$USE_OGX" = true ]; then
    echo "     - OGX Connection: (created in step 1)"
else
    echo "     - Llama Stack Connection: (created in step 1)"
fi
echo "     - Select optimization metric (e.g. Answer correctness)"
echo "     - Upload test data: sample-data/test-data.json"
echo "     - Click 'Create run'"
echo ""
echo "  3. EVALUATE AND USE:"
echo "     - Review RAG patterns on the leaderboard"
echo "     - Save indexing and inference notebooks"
echo "     - Run notebooks in a workbench"
echo ""
echo "  Sample data provided:"
echo "    Documents: sample-data/docs/ (uploaded to s3://autorag-docs/)"
echo "    Test data: sample-data/test-data.json (upload via dashboard)"
echo ""
