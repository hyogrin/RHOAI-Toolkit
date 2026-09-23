#!/bin/bash
###############################################################################
# sno-setup-maas-35.sh
#
# Set up MaaS (Models-as-a-Service) infrastructure on an SNO cluster
# running RHOAI 3.5. Deploys a POC PostgreSQL, configures Authorino TLS
# via OpenShift service-ca, and optionally sets up Redis rate limiting.
#
# Key design decisions (RHOAI 3.5.1):
#   - maas-db-config secret goes in redhat-ai-gateway-infra (not redhat-ods-applications)
#   - Authorino CR uses v1beta1 API
#   - Authorino is created WITHOUT TLS first, then service-ca generates
#     the cert, then TLS is enabled (avoids chicken-and-egg deadlock)
#   - PostgreSQL DB URL uses FQDN for cross-namespace DNS resolution
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

# The namespace where maas-api and Authorino run in RHOAI 3.5.1
MAAS_INFRA_NS="redhat-ai-gateway-infra"

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

# Ensure MaaS infra namespace exists
if ! oc get ns "$MAAS_INFRA_NS" &>/dev/null 2>&1; then
    warn "$MAAS_INFRA_NS namespace not found — will be created by operator"
    info "Waiting for $MAAS_INFRA_NS namespace (up to 120s)..."
    WAIT=0
    while [ $WAIT -lt 120 ]; do
        oc get ns "$MAAS_INFRA_NS" &>/dev/null 2>&1 && break
        sleep 5; WAIT=$((WAIT + 5))
    done
    if ! oc get ns "$MAAS_INFRA_NS" &>/dev/null 2>&1; then
        error "$MAAS_INFRA_NS namespace not created. Ensure aigateway is Managed in DSC."
        exit 1
    fi
fi
success "Namespace: $MAAS_INFRA_NS ✓"

echo ""

# Determine the namespace where PostgreSQL is deployed
PG_DEPLOY_NS="redhat-ods-applications"

###############################################################################
# Step 1. PostgreSQL database
#   PostgreSQL deploys in redhat-ods-applications.
#   maas-db-config secret goes in redhat-ai-gateway-infra (where maas-api runs).
#   DB URL must use FQDN for cross-namespace DNS resolution.
###############################################################################
info "=== Step 1/4: PostgreSQL database ==="

if oc get secret maas-db-config -n "$MAAS_INFRA_NS" &>/dev/null; then
    success "maas-db-config secret already exists in $MAAS_INFRA_NS [SKIP]"
elif [ -n "$POSTGRES_CONNECTION" ]; then
    info "Creating maas-db-config from provided connection string..."
    printf '%s' "$POSTGRES_CONNECTION" | \
        oc create secret generic maas-db-config \
            --from-file=DB_CONNECTION_URL=/dev/stdin \
            --dry-run=client -o yaml | \
        oc label --local -f - app=maas-api --dry-run=client -o yaml | \
        oc apply -n "$MAAS_INFRA_NS" -f -
    success "maas-db-config created in $MAAS_INFRA_NS (external DB)"
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

    # Deploy PostgreSQL in redhat-ods-applications
    if [ -f "$ROOT_DIR/lib/manifests/maas/postgres-pvc.yaml" ]; then
        oc apply -n "$PG_DEPLOY_NS" -f "$ROOT_DIR/lib/manifests/maas/postgres-pvc.yaml"
        oc apply -n "$PG_DEPLOY_NS" -f "$ROOT_DIR/lib/manifests/maas/postgres-service.yaml"
        export PG_IMAGE PG_USER PG_PASSWORD PG_DB
        envsubst '${PG_IMAGE} ${PG_USER} ${PG_PASSWORD} ${PG_DB}' \
            < "$ROOT_DIR/lib/manifests/maas/postgres-deployment.yaml" | oc apply -n "$PG_DEPLOY_NS" -f -
    else
        info "Deploying PostgreSQL inline..."
        oc apply -n "$PG_DEPLOY_NS" -f - <<EOF
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
        oc rollout status deployment/postgres -n "$PG_DEPLOY_NS" --timeout=5s &>/dev/null && break
        sleep 5; WAIT=$((WAIT + 5))
    done
    success "PostgreSQL ready"

    # Build DB URL with FQDN (cross-namespace resolution)
    PG_PASSWORD_ACTUAL=$(oc get deployment postgres -n "$PG_DEPLOY_NS" \
        -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="POSTGRESQL_PASSWORD")].value}' 2>/dev/null)
    ENCODED_PW=$(printf '%s' "$PG_PASSWORD_ACTUAL" | od -An -tx1 | tr -d ' \n' | sed 's/../%&/g')
    PG_FQDN="postgres.${PG_DEPLOY_NS}.svc.cluster.local"
    DB_URL="postgresql://${PG_USER}:${ENCODED_PW}@${PG_FQDN}:5432/${PG_DB}?sslmode=disable"

    # Create maas-db-config in the MaaS infra namespace (where maas-api reads it)
    printf '%s' "$DB_URL" | \
        oc create secret generic maas-db-config \
            --from-file=DB_CONNECTION_URL=/dev/stdin \
            --dry-run=client -o yaml | \
        oc label --local -f - app=maas-api --dry-run=client -o yaml | \
        oc apply -n "$MAAS_INFRA_NS" -f -

    # Also keep a copy in redhat-ods-applications for reference
    printf '%s' "$DB_URL" | \
        oc create secret generic maas-db-config \
            --from-file=DB_CONNECTION_URL=/dev/stdin \
            --dry-run=client -o yaml | \
        oc label --local -f - app=maas-api --dry-run=client -o yaml | \
        oc apply -n "$PG_DEPLOY_NS" -f -

    oc create secret generic postgres-creds \
        --from-literal=user="$PG_USER" \
        --from-literal=password="$PG_PASSWORD_ACTUAL" \
        --from-literal=database="$PG_DB" \
        -n "$PG_DEPLOY_NS" --dry-run=client -o yaml | \
        oc apply -n "$PG_DEPLOY_NS" -f -

    success "maas-db-config created in $MAAS_INFRA_NS (FQDN: $PG_FQDN)"
fi
echo ""

###############################################################################
# Step 2. Authorino + TLS (service-ca method)
#   Order: create Authorino WITHOUT TLS → wait for service → annotate for
#   service-ca cert → wait for cert → patch to enable TLS.
#   This avoids the chicken-and-egg problem where Authorino won't start
#   without the TLS cert, but the cert can't be generated without the service.
###############################################################################
info "=== Step 2/4: Authorino + TLS configuration ==="

# Detect Authorino CRD API version
AUTHORINO_API_VERSION="operator.authorino.kuadrant.io/v1beta1"
if oc get crd authorinos.operator.authorino.kuadrant.io -o jsonpath='{.spec.versions[*].name}' 2>/dev/null | grep -q "v1beta2"; then
    AUTHORINO_API_VERSION="operator.authorino.kuadrant.io/v1beta2"
fi
info "Authorino API: $AUTHORINO_API_VERSION"

# Check if Authorino is already running with TLS
AUTHORINO_READY=$(oc get authorino authorino -n "$MAAS_INFRA_NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
AUTHORINO_TLS=$(oc get authorino authorino -n "$MAAS_INFRA_NS" \
    -o jsonpath='{.spec.listener.tls.enabled}' 2>/dev/null || true)

if [ "$AUTHORINO_READY" = "True" ] && [ "$AUTHORINO_TLS" = "true" ]; then
    success "Authorino already running with TLS ✓"
else
    # Step 2a: Create or patch Authorino WITHOUT TLS to get the service created
    info "Creating Authorino instance (TLS disabled initially)..."
    oc apply -f - <<EOF
apiVersion: ${AUTHORINO_API_VERSION}
kind: Authorino
metadata:
  name: authorino
  namespace: ${MAAS_INFRA_NS}
spec:
  authConfigLabelSelectors: security.opendatahub.io/authorization-group=default
  clusterWide: true
  listener:
    tls:
      enabled: false
  oidcServer:
    tls:
      enabled: false
EOF

    # Step 2b: Wait for Authorino service to appear
    info "Waiting for Authorino service..."
    WAIT=0
    while [ $WAIT -lt 90 ]; do
        if oc get svc authorino-authorino-authorization -n "$MAAS_INFRA_NS" &>/dev/null 2>&1; then
            success "Authorino service created"
            break
        fi
        sleep 5; WAIT=$((WAIT + 5))
    done

    if ! oc get svc authorino-authorino-authorization -n "$MAAS_INFRA_NS" &>/dev/null 2>&1; then
        warn "Authorino service not created after 90s — check operator logs"
    else
        # Step 2c: Annotate service for service-ca TLS cert generation
        info "Annotating service for service-ca TLS cert..."
        oc annotate service authorino-authorino-authorization \
            -n "$MAAS_INFRA_NS" \
            service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert \
            --overwrite

        # Step 2d: Wait for service-ca to generate the cert
        info "Waiting for TLS cert generation..."
        WAIT=0
        while [ $WAIT -lt 60 ]; do
            if oc get secret authorino-server-cert -n "$MAAS_INFRA_NS" &>/dev/null 2>&1; then
                success "TLS cert generated (authorino-server-cert)"
                break
            fi
            sleep 3; WAIT=$((WAIT + 3))
        done

        if oc get secret authorino-server-cert -n "$MAAS_INFRA_NS" &>/dev/null 2>&1; then
            # Step 2e: Enable TLS on Authorino
            info "Enabling TLS on Authorino..."
            oc patch authorino authorino -n "$MAAS_INFRA_NS" --type=merge -p '{
              "spec": {
                "listener": {
                  "tls": {
                    "enabled": true,
                    "certSecretRef": { "name": "authorino-server-cert" }
                  }
                }
              }
            }'

            # Wait for Authorino to reconcile with TLS
            info "Waiting for Authorino to become ready with TLS..."
            WAIT=0
            while [ $WAIT -lt 60 ]; do
                READY=$(oc get authorino authorino -n "$MAAS_INFRA_NS" \
                    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
                [ "$READY" = "True" ] && break
                sleep 5; WAIT=$((WAIT + 5))
            done

            READY=$(oc get authorino authorino -n "$MAAS_INFRA_NS" \
                -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
            [ "$READY" = "True" ] && success "Authorino ready with TLS ✓" || \
                warn "Authorino not fully ready yet (will reconcile in background)"
        else
            warn "TLS cert not generated after 60s — Authorino running without TLS"
        fi
    fi
fi

# Annotate MaaS gateway for Authorino TLS bootstrap
oc annotate gateway maas-default-gateway \
    -n openshift-ingress \
    security.opendatahub.io/authorino-tls-bootstrap="true" \
    --overwrite 2>/dev/null || warn "Could not annotate maas-default-gateway"

success "Authorino + TLS configuration complete"
echo ""

###############################################################################
# Step 3. Rate limiting (Redis + EnvoyFilters)
###############################################################################
if [ "$SKIP_RATE_LIMITING" = true ]; then
    info "=== Step 3/4: Rate limiting [SKIPPED] ==="
    echo ""
else
    info "=== Step 3/4: Rate limiting (Redis + EnvoyFilters) ==="

    # Redis for rate limiting
    if oc get deployment limitador-redis -n "$MAAS_INFRA_NS" &>/dev/null; then
        success "Redis already deployed ✓"
    else
        info "Deploying Redis..."
        oc apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: limitador-redis
  namespace: ${MAAS_INFRA_NS}
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
  namespace: ${MAAS_INFRA_NS}
spec:
  selector: { app: limitador-redis }
  ports: [{ port: 6379, targetPort: 6379 }]
EOF
        oc rollout status deployment/limitador-redis -n "$MAAS_INFRA_NS" --timeout=60s 2>/dev/null || true
        success "Redis deployed"
    fi

    # Redis connection secret
    if ! oc get secret limitador-redis-config -n "$MAAS_INFRA_NS" &>/dev/null; then
        oc create secret generic limitador-redis-config \
            --from-literal=URL="redis://limitador-redis.${MAAS_INFRA_NS}.svc.cluster.local:6379" \
            -n "$MAAS_INFRA_NS"
    fi

    # Patch Limitador for redis-cached storage (CRD may not exist in all versions)
    if oc get crd limitadors.limitador.kuadrant.io &>/dev/null 2>&1; then
        CURRENT_STORAGE=$(oc get limitador limitador -n "$MAAS_INFRA_NS" \
            -o jsonpath='{.spec.storage.redis-cached}' 2>/dev/null || true)
        if [ -z "$CURRENT_STORAGE" ]; then
            info "Configuring Limitador with redis-cached storage..."
            if oc patch limitador limitador -n "$MAAS_INFRA_NS" --type=merge -p '{
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

    # Restart MaaS gateway to pick up EnvoyFilter changes
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
# Restart maas-api to pick up new secrets
###############################################################################
info "Restarting maas-api to pick up configuration..."
oc rollout restart deployment/maas-api -n "$MAAS_INFRA_NS" 2>/dev/null || true
WAIT=0
while [ $WAIT -lt 60 ]; do
    if oc get pods -n "$MAAS_INFRA_NS" --no-headers 2>/dev/null | grep "maas-api" | grep -q "Running"; then
        READY=$(oc get pods -n "$MAAS_INFRA_NS" -l app=maas-api -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || true)
        [ "$READY" = "true" ] && break
    fi
    sleep 5; WAIT=$((WAIT + 5))
done
if oc get pods -n "$MAAS_INFRA_NS" --no-headers 2>/dev/null | grep "maas-api" | grep -q "1/1.*Running"; then
    success "maas-api running ✓"
else
    warn "maas-api not fully ready yet — check: oc logs deployment/maas-api -n $MAAS_INFRA_NS"
fi
echo ""

###############################################################################
# Step 4. Verification
###############################################################################
info "=== Step 4/4: Verification ==="

# maas-db-config
if oc get secret maas-db-config -n "$MAAS_INFRA_NS" &>/dev/null; then
    HAS_URL=$(oc get secret maas-db-config -n "$MAAS_INFRA_NS" \
        -o jsonpath='{.data.DB_CONNECTION_URL}' 2>/dev/null)
    [ -n "$HAS_URL" ] && echo "  ✅ maas-db-config in $MAAS_INFRA_NS" || echo "  ⬚  maas-db-config (missing URL key)"
else
    echo "  ⬚  maas-db-config NOT FOUND in $MAAS_INFRA_NS"
fi

# Authorino TLS
TLS_ENABLED=$(oc get authorino authorino -n "$MAAS_INFRA_NS" \
    -o jsonpath='{.spec.listener.tls.enabled}' 2>/dev/null || true)
AUTHORINO_READY=$(oc get authorino authorino -n "$MAAS_INFRA_NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
if [ "$TLS_ENABLED" = "true" ] && [ "$AUTHORINO_READY" = "True" ]; then
    echo "  ✅ Authorino TLS enabled & ready"
elif [ "$TLS_ENABLED" = "true" ]; then
    echo "  ⬚  Authorino TLS enabled but not ready yet"
else
    echo "  ⬚  Authorino TLS not enabled"
fi

# maas-api
MAAS_API_RUNNING=$(oc get pods -n "$MAAS_INFRA_NS" --no-headers 2>/dev/null | grep "maas-api" | grep -c "1/1.*Running" || true)
[ "$MAAS_API_RUNNING" -ge 1 ] && echo "  ✅ maas-api running" || echo "  ⬚  maas-api not running"

# MaaS Tenant
TENANT_READY=$(oc get tenant default-tenant -n models-as-a-service \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
if [ "$TENANT_READY" = "True" ]; then
    echo "  ✅ MaaS Tenant ready"
else
    TENANT_MSG=$(oc get tenant default-tenant -n models-as-a-service \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || true)
    echo "  ⬚  MaaS Tenant (${TENANT_MSG:-not found yet — may take a few minutes})"
fi

# ModelsAsAServiceReady — poll every 30s until ready (up to 5 min)
MAAS_STATUS=$(oc get datasciencecluster default-dsc \
    -o jsonpath='{.status.conditions[?(@.type=="ModelsAsAServiceReady")].status}' 2>/dev/null || true)
if [ "$MAAS_STATUS" = "True" ]; then
    echo "  ✅ ModelsAsAServiceReady"
else
    echo "  ⬚  ModelsAsAServiceReady — waiting for reconciliation..."
    echo ""
    info "Polling ModelsAsAServiceReady every 30s (up to 5 min)..."
    WAIT=0
    while [ $WAIT -lt 300 ]; do
        sleep 30; WAIT=$((WAIT + 30))
        MAAS_STATUS=$(oc get datasciencecluster default-dsc \
            -o jsonpath='{.status.conditions[?(@.type=="ModelsAsAServiceReady")].status}' 2>/dev/null || true)
        if [ "$MAAS_STATUS" = "True" ]; then
            success "ModelsAsAServiceReady ✓ (after ${WAIT}s)"
            break
        fi
        MAAS_REASON=$(oc get datasciencecluster default-dsc \
            -o jsonpath='{.status.conditions[?(@.type=="ModelsAsAServiceReady")].reason}' 2>/dev/null || true)
        MAAS_MSG=$(oc get datasciencecluster default-dsc \
            -o jsonpath='{.status.conditions[?(@.type=="ModelsAsAServiceReady")].message}' 2>/dev/null || true)
        info "[${WAIT}s] ${MAAS_REASON:-NotReady}: ${MAAS_MSG:-(waiting...)}"
    done
    if [ "$MAAS_STATUS" != "True" ]; then
        warn "ModelsAsAServiceReady still not True after 5 min"
        warn "Check: oc get datasciencecluster default-dsc -o jsonpath='{.status.conditions[?(@.type==\"ModelsAsAServiceReady\")]}'"
    fi
fi

CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')

echo ""
echo "=============================================="
success "MaaS setup complete!"
echo ""
echo "  MaaS endpoint:  https://maas.${CLUSTER_DOMAIN}"
DASHBOARD_URL=$(oc get route data-science-gateway -n redhat-ods-applications -o jsonpath='{.spec.host}' 2>/dev/null || \
               oc get route rh-ai -n redhat-ods-applications -o jsonpath='{.spec.host}' 2>/dev/null || \
               echo "data-science-gateway.${CLUSTER_DOMAIN}")
echo "  Dashboard:      https://${DASHBOARD_URL}"
echo ""
echo "  Deploy a model via Dashboard → Models → llm-d runtime"
echo "  or use LLMInferenceService CR (see docs)"
echo "=============================================="
