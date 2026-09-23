#!/bin/bash
###############################################################################
# sno-enable-all-features.sh
#
# Enable all RHOAI 3.5 DSC components + dashboard features on an SNO cluster.
#
# Execution order is optimized for Web Terminal reliability:
#   Steps 1-5  — Core configuration (safe, no network disruption)
#   Step 6     — Operator install (may briefly disrupt Web Terminal)
#   Step 7     — Verification (best effort)
#
# Steps 1-5 complete before any network disruption caused by RHCL/Service
# Mesh installation. If the terminal disconnects during Step 6, operators
# continue installing via OLM in the background. Re-run the script to
# pick up where it left off — all steps are idempotent.
#
# Usage:
#   bash sno-enable-all-features.sh                 # Full run (recommended)
#   bash sno-enable-all-features.sh --skip-install   # Skip operator install
#
# Tip: In Web Terminal, run with nohup to survive disconnections:
#   nohup bash sno-enable-all-features.sh > /tmp/sno.log 2>&1 &
#   # Reconnect later:  tail -f /tmp/sno.log
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

# Operator definitions (used in Steps 6 and 7)
# Kueue, cert-manager, LWS are installed first (no network disruption).
# RHCL is installed last (triggers Service Mesh → may disrupt Web Terminal).
declare -a OP_NAMES=( "Kueue"              "cert-manager"                    "LWS (LeaderWorkerSet)"       "OpenTelemetry"                    "Tempo"                    "COO (Cluster Observability)"                      "RHCL (Red Hat Connectivity Link)" )
declare -a OP_NS=(    "openshift-operators" "cert-manager-operator"           "openshift-lws-operator"      "openshift-opentelemetry-operator" "openshift-tempo-operator" "openshift-cluster-observability-operator"          "redhat-connectivity-link-operator" )
declare -a OP_GREP=(  "kueue"              "cert-manager"                    "leader-worker-set"           "opentelemetry"                    "tempo"                    "cluster-observability-operator"                    "rhcl-operator" )
declare -a OP_SUB=(   "kueue-operator"     "openshift-cert-manager-operator" "leader-worker-set"           "opentelemetry-product"            "tempo-product"            "cluster-observability-operator"                    "rhcl-operator" )
declare -a OP_CH=(    "stable-v1.3"        "stable-v1"                       "stable-v1.0"                 "stable"                           "stable"                   "stable"                                            "stable-v1" )
declare -a OP_USE=(   "Workbenches / DW"   "KServe / Model Serving"          "llm-d distributed inference" "Metrics & trace collection"       "Distributed trace store"  "Observe & Monitor dashboard (Perses)"              "MaaS / AIGateway" )

echo "=============================================="
echo " RHOAI 3.5 SNO — Enable All Features"
echo "=============================================="
echo ""
info "Order: Config (Steps 1-5) → Operators (Step 6) → Verify (Step 7)"
info "Steps 1-5 complete before any network disruption."
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

    if [ "$NAMESPACE" = "openshift-operators" ]; then
        # openshift-operators already has Namespace + OperatorGroup
        oc apply -f - <<EOF
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
    else
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
    fi
}

###############################################################################
# Helper: check if an operator is installed
###############################################################################
check_operator_installed() {
    local idx="$1"
    if [ "${OP_SUB[$idx]}" = "rhcl-operator" ]; then
        oc get subscription -A --no-headers 2>/dev/null | grep -q "rhcl-operator"
    else
        oc get csv -n "${OP_NS[$idx]}" --no-headers 2>/dev/null | grep -q "${OP_GREP[$idx]}.*Succeeded"
    fi
}

###############################################################################
# Phase 1: Required prerequisites (abort if missing)
###############################################################################
info "=== Prerequisites ==="

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
# Step 1/7: User Workload Monitoring + DSCI Observability
#   Required for Observe & Monitor dashboard (Perses / MonitoringStack)
###############################################################################
info "=== Step 1/7: User Workload Monitoring + DSCI Observability ==="

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

# Brief wait for monitoring pods
WAIT=0
while [ "$(oc get pods -n openshift-user-workload-monitoring --no-headers 2>/dev/null | grep -c Running)" -lt 2 ]; do
    [ $WAIT -ge 60 ] && { warn "Monitoring pods wait timeout (continuing)"; break; }
    sleep 5; WAIT=$((WAIT + 5))
done

# DSCI monitoring metrics/traces config
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

# Wait for MonitoringStack (best effort — may not be ready without COO)
info "Waiting for MonitoringStack..."
MON_STATUS=""
WAIT=0
while [ $WAIT -lt 120 ]; do
    MON_STATUS=$(oc get dscinitialization default-dsci \
      -o jsonpath='{.status.conditions[?(@.type=="MonitoringStackAvailable")].status}' 2>/dev/null)
    [ "$MON_STATUS" = "True" ] && { success "MonitoringStack ✓"; break; }
    sleep 10; WAIT=$((WAIT + 10))
done
[ "${MON_STATUS:-}" != "True" ] && warn "MonitoringStack not ready yet (will reconcile in background)"
echo ""

###############################################################################
# Step 2/7: DSC component activation
###############################################################################
info "=== Step 2/7: DSC component activation ==="

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
# Step 3/7: MaaS Gateway
#   Creates GatewayClass + Gateway CRs. These are just API objects — they
#   don't require RHCL to be running yet. The gateway controller will
#   reconcile them once RHCL/Service Mesh is ready.
###############################################################################
info "=== Step 3/7: MaaS Gateway ==="

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
# Step 4/7: Dashboard menu activation
###############################################################################
info "=== Step 4/7: Dashboard menu activation ==="

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
# Step 5/7: Dashboard restart
###############################################################################
info "=== Step 5/7: Dashboard restart ==="
oc rollout restart deployment/rhods-dashboard -n redhat-ods-applications 2>/dev/null || true
info "Restarting (1-2 min)..."
sleep 10
oc rollout status deployment/rhods-dashboard -n redhat-ods-applications --timeout=120s 2>/dev/null || \
    warn "Rollout timeout — will complete shortly"
success "Dashboard restarted"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
success "Core configuration complete (Steps 1-5)."
info "Next: operator install (Step 6) may briefly disrupt Web Terminal."
info "If disconnected, re-run this script — completed steps are skipped."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

###############################################################################
# Step 6/7: Operator scan & install
#   RHCL installation triggers Service Mesh 3, which may briefly disrupt
#   the OpenShift ingress layer and Web Terminal connections.
#   Even if the terminal disconnects, OLM continues the installation.
###############################################################################
info "=== Step 6/7: Operator scan & install ==="

declare -a MISSING_NAMES=()
declare -a MISSING_NS=()
declare -a MISSING_GREP=()
declare -a MISSING_IDX=()

for i in "${!OP_NAMES[@]}"; do
    if check_operator_installed "$i"; then
        success "${OP_NAMES[$i]} ✓"
    else
        warn "${OP_NAMES[$i]} — not installed  (needed for: ${OP_USE[$i]})"
        MISSING_NAMES+=("${OP_NAMES[$i]}")
        MISSING_NS+=("${OP_NS[$i]}")
        MISSING_GREP+=("${OP_GREP[$i]}")
        MISSING_IDX+=("$i")
    fi
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
        info "RHCL triggers Service Mesh — Web Terminal may briefly disconnect."
        echo ""
        for j in "${!MISSING_IDX[@]}"; do
            idx=${MISSING_IDX[$j]}
            install_operator "${OP_NAMES[$idx]}" "${OP_NS[$idx]}" "${OP_SUB[$idx]}" "${OP_CH[$idx]}"
        done
        echo ""

        # Wait for operators (best effort — OLM handles it regardless)
        info "Waiting for operators (up to 4min)..."
        TIMEOUT=240; WAIT=0
        while [ $WAIT -lt "$TIMEOUT" ]; do
            ALL_READY=true
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
    fi
else
    success "All additional operators installed ✓"
fi

# LWS operator CR (requires LWS operator)
if oc get crd leaderworkersetoperators.operator.openshift.io &>/dev/null 2>&1; then
    if ! oc get leaderworkersetoperator cluster -n openshift-lws-operator &>/dev/null 2>&1; then
        info "Creating LeaderWorkerSet operator CR..."
        oc apply -f - <<'EOF'
apiVersion: operator.openshift.io/v1
kind: LeaderWorkerSetOperator
metadata:
  name: cluster
  namespace: openshift-lws-operator
spec:
  managementState: Managed
  logLevel: Normal
  operatorLogLevel: Normal
EOF
        success "LeaderWorkerSetOperator CR created"
    else
        success "LeaderWorkerSetOperator CR already exists ✓"
    fi
else
    warn "LWS CRD not ready yet — LeaderWorkerSetOperator CR will be created on next run"
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
else
    warn "COO not ready yet — UIPlugins will be configured on next run"
fi
echo ""

###############################################################################
# Step 7/7: Verification
###############################################################################
info "=== Step 7/7: Verification ==="
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
    if check_operator_installed "$i"; then
        echo "  ✅ ${OP_NAMES[$i]}"
    else
        echo "  ⬚  ${OP_NAMES[$i]}"
    fi
done

echo ""
info "Observability:"
MON_STATUS=$(oc get dscinitialization default-dsci \
  -o jsonpath='{.status.conditions[?(@.type=="MonitoringStackAvailable")].status}' 2>/dev/null)
PERSES_STATUS=$(oc get dscinitialization default-dsci \
  -o jsonpath='{.status.conditions[?(@.type=="PersesAvailable")].status}' 2>/dev/null)
[ "${MON_STATUS:-}" = "True" ] && echo "  ✅ MonitoringStack" || echo "  ⬚  MonitoringStack"
[ "${PERSES_STATUS:-}" = "True" ] && echo "  ✅ Perses" || echo "  ⬚  Perses"

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
echo ""
echo "  * If some operators show ⬚, re-run this script."
echo "    Operators installed by OLM continue in the background."
echo "=============================================="
