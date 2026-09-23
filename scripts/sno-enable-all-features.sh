#!/bin/bash
###############################################################################
# sno-enable-all-features.sh
#
# Enable all RHOAI 3.5 DSC components + dashboard features on an SNO cluster
# in a single run.
#
# Usage:
#   bash sno-enable-all-features.sh                # Auto-install missing operators + enable all
#   bash sno-enable-all-features.sh --skip-install  # Skip operator install (config only)
#
# Prerequisites:
#   - oc login completed
#   - RHOAI 3.5.x Operator installed
#   - DataScienceCluster 'default-dsc' exists
###############################################################################
set -euo pipefail

SKIP_INSTALL=false
[[ "${1:-}" == "--skip-install" || "${1:-}" == "--skip" ]] && SKIP_INSTALL=true

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; }

echo "=============================================="
echo " RHOAI 3.5 SNO — Enable All Features"
echo "=============================================="
echo ""

###############################################################################
# Helper: install operator via Subscription
###############################################################################
install_operator() {
    local DISPLAY_NAME="$1"
    local NAMESPACE="$2"
    local SUB_NAME="$3"
    local CHANNEL="${4:-stable}"

    info "Installing ${DISPLAY_NAME}..."
    oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${SUB_NAME}-group
  namespace: ${NAMESPACE}
spec:
  upgradeStrategy: Default
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${SUB_NAME}
  namespace: ${NAMESPACE}
spec:
  channel: ${CHANNEL}
  installPlanApproval: Automatic
  name: ${SUB_NAME}
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
}

wait_for_operators() {
    local TIMEOUT="${1:-240}"
    local WAIT=0
    info "Waiting for operators (up to $((TIMEOUT/60))min)..."
    while [ $WAIT -lt "$TIMEOUT" ]; do
        local ALL_READY=true
        for i in "${!MISSING_NS[@]}"; do
            if ! oc get csv -n "${MISSING_NS[$i]}" 2>/dev/null | grep -q "${MISSING_GREP[$i]}.*Succeeded"; then
                ALL_READY=false
            fi
        done
        $ALL_READY && break
        sleep 10; WAIT=$((WAIT + 10))
    done
    for i in "${!MISSING_NAMES[@]}"; do
        if oc get csv -n "${MISSING_NS[$i]}" 2>/dev/null | grep -q "${MISSING_GREP[$i]}.*Succeeded"; then
            success "${MISSING_NAMES[$i]} ✓"
        else
            warn "${MISSING_NAMES[$i]} — still installing (continues in background)"
        fi
    done
}

###############################################################################
# Phase 1: Required prerequisites (abort if missing)
###############################################################################
info "=== Phase 1: Required prerequisites ==="

if ! oc whoami &>/dev/null; then
    error "oc login required"
    exit 1
fi
success "Logged in: $(oc whoami) @ $(oc whoami --show-server)"

RHOAI_CSV=$(oc get csv -n redhat-ods-operator --no-headers 2>/dev/null | grep rhods | awk '{print $1}')
if [ -z "$RHOAI_CSV" ]; then
    error "RHOAI Operator not installed"
    echo "  → Install 'Red Hat OpenShift AI' from OperatorHub first"
    exit 1
fi
success "RHOAI: $(echo "$RHOAI_CSV" | sed 's/rhods-operator\.//')"

if ! oc get datasciencecluster default-dsc &>/dev/null; then
    error "DataScienceCluster 'default-dsc' not found"
    exit 1
fi
success "DSC: default-dsc"
echo ""

###############################################################################
# Phase 2: Additional operators — check & auto-install if missing
###############################################################################
info "=== Phase 2: Additional operator scan ==="

declare -a OP_NAMES=( "RHCL (Red Hat Connectivity Link)" "OpenTelemetry"                    "Tempo"                    "COO (Cluster Observability)" )
declare -a OP_NS=(    "redhat-connectivity-link-operator" "openshift-opentelemetry-operator" "openshift-tempo-operator" "openshift-cluster-observability-operator" )
declare -a OP_GREP=(  "rhcl-operator"                     "opentelemetry"                    "tempo"                    "cluster-observability-operator" )
declare -a OP_SUB=(   "rhcl-operator"                     "opentelemetry-product"            "tempo-product"            "cluster-observability-operator" )
declare -a OP_CH=(    "stable-v1"                         "stable"                           "stable"                   "stable" )
declare -a OP_USE=(   "MaaS / AIGateway"                  "Metrics & trace collection"       "Distributed trace store"  "Observe & Monitor dashboard (Perses)" )

declare -a MISSING_NAMES=()
declare -a MISSING_NS=()
declare -a MISSING_GREP=()
declare -a MISSING_IDX=()

for i in "${!OP_NAMES[@]}"; do
    FOUND=false
    if [ "${OP_SUB[$i]}" = "rhcl-operator" ]; then
        # RHCL may run in AllNamespaces mode — check Subscription instead of CSV
        oc get subscription -A --no-headers 2>/dev/null | grep -q "rhcl-operator" && FOUND=true
    else
        oc get csv -n "${OP_NS[$i]}" --no-headers 2>/dev/null | grep -q "${OP_GREP[$i]}.*Succeeded" && FOUND=true
    fi
    if $FOUND; then
        success "${OP_NAMES[$i]} ✓"
        continue
    fi
    warn "${OP_NAMES[$i]} — not installed  (needed for: ${OP_USE[$i]})"
    MISSING_NAMES+=("${OP_NAMES[$i]}")
    MISSING_NS+=("${OP_NS[$i]}")
    MISSING_GREP+=("${OP_GREP[$i]}")
    MISSING_IDX+=("$i")
done

echo ""

if [ ${#MISSING_NAMES[@]} -gt 0 ]; then
    echo -e "${BOLD}┌─────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}│  ${#MISSING_NAMES[@]} operator(s) not installed                          │${NC}"
    echo -e "${BOLD}├─────────────────────────────────────────────────────────┤${NC}"
    for j in "${!MISSING_NAMES[@]}"; do
        printf "${BOLD}│${NC}  %-3s %-30s → %s\n" "$((j+1))." "${MISSING_NAMES[$j]}" "${OP_USE[${MISSING_IDX[$j]}]}"
    done
    echo -e "${BOLD}└─────────────────────────────────────────────────────────┘${NC}"

    if [ "$SKIP_INSTALL" = true ]; then
        warn "Skipping operator install (--skip-install)"
        warn "Some features may not work without these operators"
        echo -e "  Install manually: Console → Operators → OperatorHub"
        CONSOLE_URL=$(oc whoami --show-console 2>/dev/null || echo "")
        [ -n "$CONSOLE_URL" ] && echo -e "  ${CYAN}${CONSOLE_URL}/operatorhub${NC}"
        echo ""
    else
        info "Auto-installing missing operators..."
        echo ""
        for j in "${!MISSING_IDX[@]}"; do
            idx=${MISSING_IDX[$j]}
            install_operator "${OP_NAMES[$idx]}" "${OP_NS[$idx]}" "${OP_SUB[$idx]}" "${OP_CH[$idx]}"
        done
        echo ""
        wait_for_operators 240
    fi
else
    success "All additional operators installed ✓"
fi

# UIPlugins (requires COO)
if oc get crd uiplugins.observability.openshift.io &>/dev/null 2>&1; then
    info "Configuring UIPlugins..."
    oc apply -f - <<'EOF'
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: dashboards
spec:
  type: Dashboards
---
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: monitoring
spec:
  type: Monitoring
  monitoring:
    perses:
      enabled: true
EOF
    success "UIPlugins (dashboards + monitoring) configured"
fi
echo ""

###############################################################################
# Step 1. User Workload Monitoring + DSCI Observability
#         Required for GPUaaS dashboard and Observe & Monitor menu
###############################################################################
info "=== Step 1/6: User Workload Monitoring + DSCI Observability ==="

if oc get configmap cluster-monitoring-config -n openshift-monitoring &>/dev/null 2>&1; then
    EXISTING=$(oc get configmap cluster-monitoring-config -n openshift-monitoring \
      -o jsonpath='{.data.config\.yaml}' 2>/dev/null)
    if echo "$EXISTING" | grep -q "enableUserWorkload: true"; then
        success "User Workload Monitoring already enabled ✓"
    else
        warn "cluster-monitoring-config exists but enableUserWorkload not set — patching"
        oc apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF
        success "User Workload Monitoring enabled"
    fi
else
    oc apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF
    success "User Workload Monitoring enabled"
fi

# Wait for monitoring pods
WAIT=0
while [ "$(oc get pods -n openshift-user-workload-monitoring --no-headers 2>/dev/null | grep -c Running)" -lt 2 ]; do
    [ $WAIT -ge 60 ] && { warn "Monitoring pods wait timeout (continuing)"; break; }
    sleep 5; WAIT=$((WAIT + 5))
done

# DSCI monitoring metrics/traces config (required for Observe & Monitor dashboard)
# Without metrics.storage, Perses/MonitoringStack will not start
info "Configuring DSCI observability..."
METRICS_CONFIGURED=$(oc get dscinitialization default-dsci \
  -o jsonpath='{.spec.monitoring.metrics.storage.size}' 2>/dev/null)
if [ -n "$METRICS_CONFIGURED" ]; then
    success "DSCI metrics already configured (storage: $METRICS_CONFIGURED) ✓"
else
    oc patch dscinitialization default-dsci --type=merge -p '{
      "spec": {
        "monitoring": {
          "managementState": "Managed",
          "namespace": "redhat-ods-monitoring",
          "alerting": {},
          "metrics": {
            "replicas": 1,
            "storage": {
              "size": "5Gi",
              "retention": "90d"
            }
          },
          "traces": {
            "sampleRatio": "0.1",
            "storage": {
              "backend": "pv",
              "retention": "2160h"
            }
          }
        }
      }
    }'
    success "DSCI metrics/traces configured"
fi

# Wait for MonitoringStack
info "Waiting for MonitoringStack..."
WAIT=0
while [ $WAIT -lt 120 ]; do
    MON_STATUS=$(oc get dscinitialization default-dsci \
      -o jsonpath='{.status.conditions[?(@.type=="MonitoringStackAvailable")].status}' 2>/dev/null)
    [ "$MON_STATUS" = "True" ] && { success "MonitoringStack ✓"; break; }
    sleep 10; WAIT=$((WAIT + 10))
done
[ "$MON_STATUS" != "True" ] && warn "MonitoringStack not ready yet (continuing)"
echo ""

###############################################################################
# Step 2. DSC patch — enable backend components
#         mlflowoperator / ogx / aigateway+MaaS / llamastackoperator Removed
###############################################################################
info "=== Step 2/6: DSC component activation ==="

oc patch datasciencecluster default-dsc --type=merge -p '{
  "spec": {
    "components": {
      "mlflowoperator": {
        "managementState": "Managed"
      },
      "llamastackoperator": {
        "managementState": "Removed"
      },
      "ogx": {
        "managementState": "Managed"
      },
      "aigateway": {
        "managementState": "Managed",
        "modelsAsAService": {
          "managementState": "Managed"
        }
      }
    }
  }
}' 2>&1

success "DSC patched"

# Wait for OGX CRD
info "Waiting for OGX provisioning..."
WAIT=0
while ! oc get crd ogxservers.ogx.io &>/dev/null 2>&1; do
    [ $WAIT -ge 90 ] && { warn "OGX CRD wait timeout (continuing)"; break; }
    sleep 5; WAIT=$((WAIT + 5))
done
oc get crd ogxservers.ogx.io &>/dev/null 2>&1 && success "OGX CRD registered ✓"
echo ""

###############################################################################
# Step 3. MaaS Gateway
#         Required after AIGateway is enabled
###############################################################################
info "=== Step 3/6: MaaS Gateway ==="

CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')

CERT_NAME=$(oc get secrets -n openshift-ingress --no-headers 2>/dev/null | \
  grep "cert-manager-ingress-cert\|router-certs-default" | awk '{print $1}' | head -1)
if [ -z "$CERT_NAME" ]; then
    warn "TLS cert not found — using cert-manager-ingress-cert"
    CERT_NAME="cert-manager-ingress-cert"
fi
info "Domain: $CLUSTER_DOMAIN, TLS: $CERT_NAME"

# GatewayClass (idempotent)
oc apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: maas-gateway-class
spec:
  controllerName: openshift.io/gateway-controller/v1
EOF

# Gateway
if oc get gateway maas-default-gateway -n openshift-ingress &>/dev/null 2>&1; then
    success "maas-default-gateway already exists ✓"
else
    oc apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: maas-default-gateway
  namespace: openshift-ingress
  labels:
    istio.io/rev: openshift-gateway
  annotations:
    opendatahub.io/managed: "false"
    security.opendatahub.io/authorino-tls-bootstrap: "true"
spec:
  gatewayClassName: maas-gateway-class
  listeners:
    - allowedRoutes:
        namespaces:
          from: All
      hostname: "maas.${CLUSTER_DOMAIN}"
      name: https
      port: 443
      protocol: HTTPS
      tls:
        certificateRefs:
          - group: ''
            kind: Secret
            name: ${CERT_NAME}
        mode: Terminate
EOF
    success "maas-default-gateway created"
fi
echo ""

###############################################################################
# Step 4. OdhDashboardConfig — enable all dashboard menus
###############################################################################
info "=== Step 4/6: Dashboard menu activation ==="

WAIT=0
while ! oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications &>/dev/null; do
    [ $WAIT -ge 60 ] && { error "OdhDashboardConfig not found"; exit 1; }
    sleep 5; WAIT=$((WAIT + 5))
done

oc patch odhdashboardconfig odh-dashboard-config \
  -n redhat-ods-applications --type=merge -p '{
  "spec": {
    "dashboardConfig": {
      "disableModelRegistry": false,
      "disableModelCatalog": false,
      "disableKServeMetrics": false,
      "disableLMEval": false,
      "disableKueue": false,
      "disableTracking": false,
      "disablePerformanceMetrics": false,
      "disableDistributedWorkloads": false,
      "disableTrustyBiasMetrics": false,
      "genAiStudio": true,
      "modelAsService": true,
      "vLLMDeploymentOnMaaS": true,
      "observabilityDashboard": true,
      "mcpCatalog": true,
      "llmGatewayField": true,
      "deploymentWizardYAMLViewer": true,
      "aiAssetCustomEndpoints": true,
      "roleManagement": true,
      "gpuaas": true,
      "agentOps": true,
      "agentsCatalog": true,
      "agentConfigManagement": true,
      "automl": true,
      "autorag": true,
      "connectionTest": true,
      "externalModels": true,
      "externalVectorStores": true,
      "featureStoreAdmin": true,
      "genAiTracing": true,
      "globalProjectPrompts": true,
      "guardrails": true,
      "llmdTemplates": true,
      "mcpRegistry": true,
      "projectRBAC": true,
      "promptManagement": true,
      "toolCalling": true,
      "trainingJobs": true
    }
  }
}'

success "Dashboard menu patched"
echo ""

###############################################################################
# Step 5. Restart dashboard
###############################################################################
info "=== Step 5/6: Dashboard restart ==="
oc rollout restart deployment/rhods-dashboard -n redhat-ods-applications 2>/dev/null || true
info "Restarting (1-2 min)..."
sleep 10
oc rollout status deployment/rhods-dashboard -n redhat-ods-applications --timeout=120s 2>/dev/null || \
    warn "Rollout timeout — will complete shortly"
success "Dashboard restarted"
echo ""

###############################################################################
# Step 6. Verification
###############################################################################
info "=== Step 6/6: Verification ==="
info "DSC components:"
for comp in MLflowOperatorReady OGXReady AIGatewayReady KserveReady TrustyAIReady AIPipelinesReady DashboardReady WorkbenchesReady ModelsAsAServiceReady; do
    STATUS=$(oc get datasciencecluster default-dsc -o jsonpath="{.status.conditions[?(@.type==\"${comp}\")].status}" 2>/dev/null)
    REASON=$(oc get datasciencecluster default-dsc -o jsonpath="{.status.conditions[?(@.type==\"${comp}\")].reason}" 2>/dev/null)
    if [ "$STATUS" = "True" ]; then
        echo "  ✅ ${comp}"
    else
        echo "  ⬚  ${comp} (${REASON:-pending})"
    fi
done

echo ""
info "Operators:"
for i in "${!OP_NAMES[@]}"; do
    OP_OK=false
    if [ "${OP_SUB[$i]}" = "rhcl-operator" ]; then
        oc get subscription -A --no-headers 2>/dev/null | grep -q "rhcl-operator" && OP_OK=true
    else
        oc get csv -n "${OP_NS[$i]}" --no-headers 2>/dev/null | grep -q "${OP_GREP[$i]}.*Succeeded" && OP_OK=true
    fi
    $OP_OK && echo "  ✅ ${OP_NAMES[$i]}" || echo "  ⬚  ${OP_NAMES[$i]}"
done

echo ""
info "Gateway:"
oc get gateway -n openshift-ingress --no-headers 2>/dev/null | while read name class addr rest; do
    echo "  $name → $addr"
done

echo ""
info "Dashboard URL:"
echo "  https://$(oc get route data-science-gateway -n redhat-ods-applications -o jsonpath='{.spec.host}' 2>/dev/null || echo '(check manually)')"

echo ""
echo "=============================================="
success "Done! Refresh the dashboard."
echo ""
echo "  * If MaaS shows NotReady, run the MaaS setup:"
echo "    bash scripts/sno-setup-maas-35.sh"
echo "=============================================="
