#!/bin/bash
###############################################################################
# sno-setup-maas-35.sh
#
# Set up MaaS (Models-as-a-Service) infrastructure on an SNO cluster
# running RHOAI 3.5. Deploys a POC PostgreSQL, configures TLS via
# OpenShift service-ca, and optionally sets up Redis rate limiting.
#
# Usage:
#   bash sno-setup-maas-35.sh                                  # POC PostgreSQL
#   bash sno-setup-maas-35.sh --postgres-connection <url>      # External DB
#   bash sno-setup-maas-35.sh --skip-rate-limiting             # Skip Redis
#
# Prerequisites:
#   - oc login completed
#   - RHOAI 3.5+ installed with DSC 'default-dsc'
#   - RHCL operator installed
#   - aigateway + modelsAsAService enabled in DSC
#   - maas-default-gateway created
#
# Tip: Run sno-enable-all-features.sh first to ensure all prerequisites.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

POSTGRES_CONNECTION=""
SKIP_RATE_LIMITING=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --postgres-connection) POSTGRES_CONNECTION="$2"; shift 2 ;;
        --skip-rate-limiting)  SKIP_RATE_LIMITING=true; shift ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "  --postgres-connection <url>  External PostgreSQL connection URL"
            echo "                               e.g. postgresql://user:pass@host:5432/db?sslmode=require"
            echo "  --skip-rate-limiting         Skip Redis + EnvoyFilter setup"
            echo "  --help                       Show this help"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; }

echo "=============================================="
echo " RHOAI 3.5 SNO — MaaS Setup"
echo "=============================================="
echo ""

###############################################################################
# Pre-flight checks
###############################################################################
info "=== Pre-flight checks ==="

if ! oc whoami &>/dev/null; then
    error "oc login required"
    exit 1
fi
success "Logged in: $(oc whoami) @ $(oc whoami --show-server)"

RHOAI_CSV=$(oc get csv -n redhat-ods-operator --no-headers 2>/dev/null | grep rhods | awk '{print $1}')
if [ -z "$RHOAI_CSV" ]; then
    error "RHOAI Operator not installed"
    exit 1
fi
success "RHOAI: $(echo "$RHOAI_CSV" | sed 's/rhods-operator\.//')"

# Check RHCL
if oc get subscription -A --no-headers 2>/dev/null | grep -q "rhcl-operator"; then
    success "RHCL operator ✓"
else
    error "RHCL operator not installed"
    echo "  Run: bash sno-enable-all-features.sh first"
    exit 1
fi

# Check aigateway in DSC
AIGATEWAY=$(oc get datasciencecluster default-dsc \
  -o jsonpath='{.spec.components.aigateway.managementState}' 2>/dev/null)
if [ "$AIGATEWAY" != "Managed" ]; then
    error "AIGateway not enabled in DSC (current: ${AIGATEWAY:-unset})"
    echo "  Run: bash sno-enable-all-features.sh first"
    exit 1
fi
success "AIGateway: Managed ✓"

# Check maas-default-gateway
if oc get gateway maas-default-gateway -n openshift-ingress &>/dev/null 2>&1; then
    success "maas-default-gateway ✓"
else
    error "maas-default-gateway not found in openshift-ingress"
    echo "  Run: bash sno-enable-all-features.sh first"
    exit 1
fi

echo ""

###############################################################################
# Step 1. PostgreSQL database
###############################################################################
info "=== Step 1/4: PostgreSQL database ==="

if oc get secret maas-db-config -n redhat-ods-applications &>/dev/null; then
    success "maas-db-config secret already exists [SKIP]"
elif [ -n "$POSTGRES_CONNECTION" ]; then
    info "Creating maas-db-config from provided connection string..."
    printf '%s' "$POSTGRES_CONNECTION" | \
        oc create secret generic maas-db-config \
            --from-file=DB_CONNECTION_URL=/dev/stdin \
            --dry-run=client -o yaml | \
        oc label --local -f - app=maas-api --dry-run=client -o yaml | \
        oc apply -n redhat-ods-applications -f -
    success "maas-db-config created (external DB)"
else
    warn "No --postgres-connection provided. Deploying POC PostgreSQL (NOT for production)."
    info "For production: AWS RDS, Crunchy Operator, or Azure Database for PostgreSQL"
    echo ""

    PG_USER="maas"
    PG_DB="maas"
    PG_PASSWORD="$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-32)"

    # Resolve PostgreSQL image from RHOAI operator CSV
    PG_IMAGE=$(oc get csv -l 'olm.copiedFrom=redhat-ods-operator' \
        -o jsonpath='{.items[0].spec.relatedImages[?(@.name=="postgresql_16_image")].image}' 2>/dev/null) || true
    if [ -z "$PG_IMAGE" ]; then
        PG_IMAGE="registry.redhat.io/rhel9/postgresql-16:latest"
    fi
    info "PostgreSQL image: $PG_IMAGE"

    # Apply manifests
    if [ -f "$ROOT_DIR/lib/manifests/maas/postgres-pvc.yaml" ]; then
        oc apply -n redhat-ods-applications -f "$ROOT_DIR/lib/manifests/maas/postgres-pvc.yaml"
        oc apply -n redhat-ods-applications -f "$ROOT_DIR/lib/manifests/maas/postgres-service.yaml"
        export PG_IMAGE PG_USER PG_PASSWORD PG_DB
        envsubst '${PG_IMAGE} ${PG_USER} ${PG_PASSWORD} ${PG_DB}' \
            < "$ROOT_DIR/lib/manifests/maas/postgres-deployment.yaml" | oc apply -n redhat-ods-applications -f -
    else
        # Inline manifests (for standalone use without repo)
        info "Deploying PostgreSQL inline..."
        oc apply -n redhat-ods-applications -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data
  labels: { app: postgres, purpose: poc }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 20Gi } }
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  labels: { app: postgres }
spec:
  selector: { app: postgres }
  ports: [{ port: 5432, targetPort: 5432 }]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  labels: { app: postgres, purpose: poc }
spec:
  replicas: 1
  selector: { matchLabels: { app: postgres } }
  template:
    metadata: { labels: { app: postgres } }
    spec:
      containers:
      - name: postgres
        image: ${PG_IMAGE}
        ports: [{ containerPort: 5432 }]
        env:
        - { name: POSTGRESQL_USER, value: "${PG_USER}" }
        - { name: POSTGRESQL_PASSWORD, value: "${PG_PASSWORD}" }
        - { name: POSTGRESQL_DATABASE, value: "${PG_DB}" }
        volumeMounts: [{ name: data, mountPath: /var/lib/pgsql/data }]
        resources:
          requests: { cpu: 250m, memory: 512Mi }
          limits: { cpu: "1", memory: 1Gi }
        readinessProbe:
          exec: { command: ["pg_isready", "-U", "${PG_USER}", "-d", "${PG_DB}"] }
          initialDelaySeconds: 5
          periodSeconds: 5
      volumes:
      - name: data
        persistentVolumeClaim: { claimName: postgres-data }
EOF
    fi
    unset PG_PASSWORD

    info "Waiting for PostgreSQL..."
    WAIT=0
    while [ $WAIT -lt 120 ]; do
        oc rollout status deployment/postgres -n redhat-ods-applications --timeout=5s &>/dev/null && break
        sleep 5; WAIT=$((WAIT + 5))
    done
    success "PostgreSQL ready"

    # Recover password (still in PG_PASSWORD before unset — use deployment env)
    PG_PASSWORD_ACTUAL=$(oc get deployment postgres -n redhat-ods-applications \
        -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="POSTGRESQL_PASSWORD")].value}' 2>/dev/null)
    ENCODED_PW=$(printf '%s' "$PG_PASSWORD_ACTUAL" | od -An -tx1 | tr -d ' \n' | sed 's/../%&/g')
    DB_URL="postgresql://${PG_USER}:${ENCODED_PW}@postgres:5432/${PG_DB}?sslmode=disable"

    printf '%s' "$DB_URL" | \
        oc create secret generic maas-db-config \
            --from-file=DB_CONNECTION_URL=/dev/stdin \
            --dry-run=client -o yaml | \
        oc label --local -f - app=maas-api --dry-run=client -o yaml | \
        oc apply -n redhat-ods-applications -f -

    oc create secret generic postgres-creds \
        --from-literal=user="$PG_USER" \
        --from-literal=password="$PG_PASSWORD_ACTUAL" \
        --from-literal=database="$PG_DB" \
        -n redhat-ods-applications --dry-run=client -o yaml | \
        oc apply -n redhat-ods-applications -f -

    success "maas-db-config secret created (POC PostgreSQL)"
fi
echo ""

###############################################################################
# Step 2. MaaS TLS (service-ca method)
###############################################################################
info "=== Step 2/4: MaaS TLS configuration ==="

# Annotate Authorino service for OpenShift service-ca cert
info "Annotating Authorino service for service-ca TLS..."
oc annotate service authorino-authorino-authorization \
    -n kuadrant-system \
    service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert \
    --overwrite 2>/dev/null || {
    warn "Could not annotate Authorino service — may not exist in kuadrant-system"
    # Try redhat-ai-gateway-infra namespace (RHOAI 3.5 may use this)
    oc annotate service authorino-authorino-authorization \
        -n redhat-ai-gateway-infra \
        service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert \
        --overwrite 2>/dev/null || warn "Authorino service not found in either namespace"
}

# Wait for cert
info "Waiting for service-ca to generate TLS cert..."
WAIT=0
AUTHORINO_NS="kuadrant-system"
oc get ns kuadrant-system &>/dev/null 2>&1 || AUTHORINO_NS="redhat-ai-gateway-infra"
while [ $WAIT -lt 60 ]; do
    oc get secret authorino-server-cert -n "$AUTHORINO_NS" &>/dev/null && break
    sleep 5; WAIT=$((WAIT + 5))
done
oc get secret authorino-server-cert -n "$AUTHORINO_NS" &>/dev/null && \
    success "Authorino TLS cert generated ✓" || warn "TLS cert not ready yet"

# Patch Authorino CR for TLS listener
info "Patching Authorino CR..."
oc patch authorino authorino -n "$AUTHORINO_NS" --type=merge -p '{
  "spec": {
    "listener": {
      "tls": {
        "enabled": true,
        "certSecretRef": { "name": "authorino-server-cert" }
      }
    }
  }
}' 2>/dev/null || warn "Could not patch Authorino CR"

# Set TLS env vars
oc -n "$AUTHORINO_NS" set env deployment/authorino \
    SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
    2>/dev/null || warn "Could not set Authorino TLS env vars"

# Annotate gateway
oc annotate gateway maas-default-gateway \
    -n openshift-ingress \
    security.opendatahub.io/authorino-tls-bootstrap="true" \
    --overwrite 2>/dev/null || warn "Could not annotate maas-default-gateway"

success "MaaS TLS configured"
echo ""

###############################################################################
# Step 3. Rate limiting (Redis + EnvoyFilters)
###############################################################################
if [ "$SKIP_RATE_LIMITING" = true ]; then
    info "=== Step 3/4: Rate limiting [SKIPPED] ==="
    echo ""
else
    info "=== Step 3/4: Rate limiting (Redis + EnvoyFilters) ==="

    # Redis for Limitador
    if oc get deployment limitador-redis -n "$AUTHORINO_NS" &>/dev/null; then
        success "Limitador Redis already deployed ✓"
    else
        info "Deploying Redis for Limitador..."
        oc apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: limitador-redis
  namespace: ${AUTHORINO_NS}
  labels: { app: limitador-redis }
spec:
  replicas: 1
  selector: { matchLabels: { app: limitador-redis } }
  template:
    metadata: { labels: { app: limitador-redis } }
    spec:
      containers:
      - name: redis
        image: registry.redhat.io/rhel9/redis-7:latest
        ports: [{ containerPort: 6379 }]
        resources:
          requests: { cpu: 100m, memory: 128Mi }
          limits: { cpu: 500m, memory: 256Mi }
---
apiVersion: v1
kind: Service
metadata:
  name: limitador-redis
  namespace: ${AUTHORINO_NS}
spec:
  selector: { app: limitador-redis }
  ports: [{ port: 6379, targetPort: 6379 }]
EOF
        oc rollout status deployment/limitador-redis -n "$AUTHORINO_NS" --timeout=60s 2>/dev/null || true
        success "Redis deployed"
    fi

    # Redis connection secret
    if ! oc get secret limitador-redis-config -n "$AUTHORINO_NS" &>/dev/null; then
        oc create secret generic limitador-redis-config \
            --from-literal=URL="redis://limitador-redis.${AUTHORINO_NS}.svc.cluster.local:6379" \
            -n "$AUTHORINO_NS"
    fi

    # Patch Limitador for redis-cached storage (CRD may not exist in all versions)
    if oc get crd limitadors.limitador.kuadrant.io &>/dev/null 2>&1; then
        CURRENT_STORAGE=$(oc get limitador limitador -n "$AUTHORINO_NS" \
            -o jsonpath='{.spec.storage.redis-cached}' 2>/dev/null || true)
        if [ -z "$CURRENT_STORAGE" ]; then
            info "Configuring Limitador with redis-cached storage..."
            if oc patch limitador limitador -n "$AUTHORINO_NS" --type=merge -p '{
                "spec": {
                    "storage": {
                        "redis-cached": {
                            "configSecretRef": { "name": "limitador-redis-config" },
                            "options": {
                                "flush-period": 500,
                                "max-cached": 10000,
                                "batch-size": 100,
                                "response-timeout": 500
                            }
                        }
                    }
                }
            }' 2>/dev/null; then
                success "Limitador configured with Redis"
            else
                warn "Could not patch Limitador — rate limiting may use in-memory storage"
            fi
        else
            success "Limitador already using redis-cached ✓"
        fi
    else
        warn "Limitador CRD not found — skipping redis-cached config"
        warn "Rate limiting may be managed differently in this RHOAI version"
    fi

    # Health check interceptor EnvoyFilter
    if ! oc get envoyfilter healthcheck-filter -n openshift-ingress &>/dev/null; then
        info "Applying health check EnvoyFilter..."
        oc apply -f - <<'EOF'
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: healthcheck-filter
  namespace: openshift-ingress
spec:
  workloadSelector:
    labels:
      gateway.networking.k8s.io/gateway-name: maas-default-gateway
  configPatches:
    - applyTo: HTTP_FILTER
      match:
        context: GATEWAY
        listener:
          filterChain:
            filter:
              name: envoy.filters.network.http_connection_manager
      patch:
        operation: INSERT_FIRST
        value:
          name: envoy.filters.http.health_check
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.http.health_check.v3.HealthCheck
            pass_through_mode: false
            headers:
              - name: ":path"
                string_match: { exact: "/healthz" }
              - name: ":path"
                string_match: { exact: "/ready" }
EOF
        success "Health check filter applied"
    fi

    # Ratelimit cluster timeout
    if ! oc get envoyfilter increase-ratelimit-cluster-timeout -n openshift-ingress &>/dev/null; then
        info "Applying ratelimit timeout EnvoyFilter..."
        oc apply -f - <<'EOF'
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: increase-ratelimit-cluster-timeout
  namespace: openshift-ingress
spec:
  workloadSelector:
    labels:
      gateway.networking.k8s.io/gateway-name: maas-default-gateway
  configPatches:
    - applyTo: CLUSTER
      match:
        context: GATEWAY
        cluster: { name: kuadrant-ratelimit-service }
      patch:
        operation: MERGE
        value: { connect_timeout: 2s }
EOF
        success "Ratelimit timeout (2s) applied"
    fi

    # Restart gateway
    MAAS_DEPLOY=$(oc get deployment -n openshift-ingress \
        -l "gateway.networking.k8s.io/gateway-name=maas-default-gateway" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -n "$MAAS_DEPLOY" ]; then
        oc rollout restart deployment/"$MAAS_DEPLOY" -n openshift-ingress 2>/dev/null || true
    fi

    success "Rate limiting configured"
    echo ""
fi

###############################################################################
# Step 4. Verification
###############################################################################
info "=== Step 4/4: Verification ==="

# maas-db-config
if oc get secret maas-db-config -n redhat-ods-applications &>/dev/null; then
    HAS_URL=$(oc get secret maas-db-config -n redhat-ods-applications \
        -o jsonpath='{.data.DB_CONNECTION_URL}' 2>/dev/null)
    [ -n "$HAS_URL" ] && echo "  ✅ maas-db-config (DB_CONNECTION_URL set)" || echo "  ⬚  maas-db-config (missing URL key)"
else
    echo "  ⬚  maas-db-config NOT FOUND"
fi

# Authorino TLS
TLS_ENABLED=$(oc get authorino authorino -n "$AUTHORINO_NS" \
    -o jsonpath='{.spec.listener.tls.enabled}' 2>/dev/null)
[ "$TLS_ENABLED" = "true" ] && echo "  ✅ Authorino TLS enabled" || echo "  ⬚  Authorino TLS"

# MaaS Tenant
TENANT_READY=$(oc get tenant default-tenant -n models-as-a-service \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
if [ "$TENANT_READY" = "True" ]; then
    echo "  ✅ MaaS Tenant ready"
else
    TENANT_MSG=$(oc get tenant default-tenant -n models-as-a-service \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null)
    echo "  ⬚  MaaS Tenant (${TENANT_MSG:-not found yet})"
fi

# ModelsAsAServiceReady
MAAS_STATUS=$(oc get datasciencecluster default-dsc \
    -o jsonpath='{.status.conditions[?(@.type=="ModelsAsAServiceReady")].status}' 2>/dev/null)
[ "$MAAS_STATUS" = "True" ] && echo "  ✅ ModelsAsAServiceReady" || echo "  ⬚  ModelsAsAServiceReady"

CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')

echo ""
echo "=============================================="
success "MaaS setup complete!"
echo ""
echo "  MaaS endpoint:  https://maas.${CLUSTER_DOMAIN}"
echo "  Dashboard:      https://data-science-gateway.${CLUSTER_DOMAIN}"
echo ""
echo "  Deploy a model via Dashboard → Models → llm-d runtime"
echo "  or use LLMInferenceService CR (see docs)"
echo "=============================================="
