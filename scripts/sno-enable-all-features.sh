#!/bin/bash
###############################################################################
# sno-enable-all-features.sh
#
# RHOAI 3.5 SNO(Single Node OpenShift) 클러스터에서
# 모든 DSC 컴포넌트 + Dashboard 메뉴를 한번에 활성화하는 스크립트
#
# 사용법:
#   bash sno-enable-all-features.sh              # 누락 Operator 자동 설치 + 전체 활성화
#   bash sno-enable-all-features.sh --skip-install  # Operator 설치 건너뛰기 (설정만)
#
# 사전조건:
#   - oc login 완료
#   - RHOAI 3.5.x Operator 설치 완료
#   - DataScienceCluster 'default-dsc' 존재
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
# Helper: Operator 설치 & 대기 함수
###############################################################################
install_operator() {
    local DISPLAY_NAME="$1"
    local NAMESPACE="$2"
    local SUB_NAME="$3"
    local CHANNEL="${4:-stable}"

    info "${DISPLAY_NAME} 설치 중..."
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
    info "Operators 설치 대기 중 (최대 $((TIMEOUT/60))분)..."
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
    # Report results
    for i in "${!MISSING_NAMES[@]}"; do
        if oc get csv -n "${MISSING_NS[$i]}" 2>/dev/null | grep -q "${MISSING_GREP[$i]}.*Succeeded"; then
            success "${MISSING_NAMES[$i]} ✓"
        else
            warn "${MISSING_NAMES[$i]} — 아직 설치 중 (백그라운드에서 계속 진행됩니다)"
        fi
    done
}

###############################################################################
# Phase 1: 필수 사전조건 체크 (없으면 중단)
###############################################################################
info "=== Phase 1: 필수 사전조건 체크 ==="

# oc login
if ! oc whoami &>/dev/null; then
    error "oc login이 필요합니다"
    exit 1
fi
success "Logged in: $(oc whoami) @ $(oc whoami --show-server)"

# RHOAI Operator
RHOAI_CSV=$(oc get csv -n redhat-ods-operator --no-headers 2>/dev/null | grep rhods | awk '{print $1}')
if [ -z "$RHOAI_CSV" ]; then
    error "RHOAI Operator가 설치되어 있지 않습니다"
    echo "  → OperatorHub에서 'Red Hat OpenShift AI' 설치 후 재실행하세요"
    exit 1
fi
success "RHOAI: $(echo "$RHOAI_CSV" | sed 's/rhods-operator\.//')"

# DSC
if ! oc get datasciencecluster default-dsc &>/dev/null; then
    error "DataScienceCluster 'default-dsc'가 존재하지 않습니다"
    exit 1
fi
success "DSC: default-dsc"
echo ""

###############################################################################
# Phase 2: 추가 Operator 체크 (없으면 안내 + 설치 여부 질문)
###############################################################################
info "=== Phase 2: 추가 Operator 상태 스캔 ==="

# Operator 목록: DISPLAY_NAME | NAMESPACE | CSV_GREP | SUB_NAME | CHANNEL | 용도
declare -a OP_NAMES=( "RHCL (Red Hat Connectivity Link)" "OpenTelemetry"             "Tempo"                    "COO (Cluster Observability)" )
declare -a OP_NS=(    "redhat-connectivity-link-operator" "openshift-opentelemetry-operator" "openshift-tempo-operator" "openshift-cluster-observability-operator" )
declare -a OP_GREP=(  "rhcl-operator"                     "opentelemetry"             "tempo"                    "cluster-observability-operator" )
declare -a OP_SUB=(   "rhcl-operator"                     "opentelemetry-product"     "tempo-product"            "cluster-observability-operator" )
declare -a OP_CH=(    "stable-v1"                         "stable"                    "stable"                   "stable" )
declare -a OP_USE=(   "MaaS / AIGateway"                  "메트릭·트레이스 수집"       "분산 트레이스 저장"         "Observe & Monitor 대시보드 (Perses)" )

declare -a MISSING_NAMES=()
declare -a MISSING_NS=()
declare -a MISSING_GREP=()
declare -a MISSING_IDX=()

for i in "${!OP_NAMES[@]}"; do
    # RHCL은 -A로 검색 (namespace가 다를 수 있음)
    if [ "${OP_SUB[$i]}" = "rhcl-operator" ]; then
        if oc get csv -A --no-headers 2>/dev/null | grep -q "rhcl-operator.*Succeeded"; then
            success "${OP_NAMES[$i]} ✓"
            continue
        fi
    else
        if oc get csv -n "${OP_NS[$i]}" 2>/dev/null | grep -q "${OP_GREP[$i]}.*Succeeded"; then
            success "${OP_NAMES[$i]} ✓"
            continue
        fi
    fi
    warn "${OP_NAMES[$i]} — 미설치  (용도: ${OP_USE[$i]})"
    MISSING_NAMES+=("${OP_NAMES[$i]}")
    MISSING_NS+=("${OP_NS[$i]}")
    MISSING_GREP+=("${OP_GREP[$i]}")
    MISSING_IDX+=("$i")
done

echo ""

# 누락된 Operator가 있으면 설치 여부 질문
if [ ${#MISSING_NAMES[@]} -gt 0 ]; then
    echo -e "${BOLD}┌─────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}│  ${#MISSING_NAMES[@]}개 Operator가 설치되어 있지 않습니다               │${NC}"
    echo -e "${BOLD}├─────────────────────────────────────────────────────────┤${NC}"
    for j in "${!MISSING_NAMES[@]}"; do
        printf "${BOLD}│${NC}  %-3s %-30s → %s\n" "$((j+1))." "${MISSING_NAMES[$j]}" "${OP_USE[${MISSING_IDX[$j]}]}"
    done
    echo -e "${BOLD}└─────────────────────────────────────────────────────────┘${NC}"

    if [ "$SKIP_INSTALL" = true ]; then
        warn "Operator 설치를 건너뜁니다 (--skip-install)"
        warn "일부 기능이 동작하지 않을 수 있습니다"
        echo -e "  직접 설치하려면 Console → Operators → OperatorHub"
        CONSOLE_URL=$(oc whoami --show-console 2>/dev/null || echo "")
        [ -n "$CONSOLE_URL" ] && echo -e "  ${CYAN}${CONSOLE_URL}/operatorhub${NC}"
        echo ""
    else
        info "누락된 Operator를 자동 설치합니다..."
        echo ""
        for j in "${!MISSING_IDX[@]}"; do
            idx=${MISSING_IDX[$j]}
            install_operator "${OP_NAMES[$idx]}" "${OP_NS[$idx]}" "${OP_SUB[$idx]}" "${OP_CH[$idx]}"
        done
        echo ""
        wait_for_operators 240
    fi
else
    success "모든 추가 Operator 설치 완료 ✓"
fi

# UIPlugins (COO가 설치된 경우)
if oc get crd uiplugins.observability.openshift.io &>/dev/null 2>&1; then
    info "UIPlugins 설정 중..."
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
    success "UIPlugins (dashboards + monitoring) 설정 완료"
fi
echo ""

###############################################################################
# Step 1. User Workload Monitoring 활성화
#         GPUaaS Dashboard / Observability가 Prometheus 메트릭을 조회하려면 필수
###############################################################################
info "=== Step 1/5: User Workload Monitoring ==="

if oc get configmap cluster-monitoring-config -n openshift-monitoring &>/dev/null 2>&1; then
    EXISTING=$(oc get configmap cluster-monitoring-config -n openshift-monitoring \
      -o jsonpath='{.data.config\.yaml}' 2>/dev/null)
    if echo "$EXISTING" | grep -q "enableUserWorkload: true"; then
        success "이미 활성화됨 ✓"
    else
        warn "cluster-monitoring-config 존재하지만 enableUserWorkload 미설정 — 패치"
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
        success "활성화 완료"
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
    success "활성화 완료"
fi

# Wait for monitoring pods
WAIT=0
while [ "$(oc get pods -n openshift-user-workload-monitoring --no-headers 2>/dev/null | grep -c Running)" -lt 2 ]; do
    [ $WAIT -ge 60 ] && { warn "Monitoring pods 대기 timeout (계속 진행)"; break; }
    sleep 5; WAIT=$((WAIT + 5))
done
echo ""

###############################################################################
# Step 2. DSC 패치 — 백엔드 컴포넌트 활성화
#         mlflowoperator / ogx / aigateway+MaaS / llamastackoperator Removed
###############################################################################
info "=== Step 2/5: DSC 컴포넌트 활성화 ==="

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

success "DSC 패치 완료"

# Wait for OGX CRD
info "OGX 프로비저닝 대기 중..."
WAIT=0
while ! oc get crd ogxservers.ogx.io &>/dev/null 2>&1; do
    [ $WAIT -ge 90 ] && { warn "OGX CRD 대기 timeout (계속 진행)"; break; }
    sleep 5; WAIT=$((WAIT + 5))
done
oc get crd ogxservers.ogx.io &>/dev/null 2>&1 && success "OGX CRD 등록 완료 ✓"
echo ""

###############################################################################
# Step 3. MaaS Gateway 생성
#         AIGateway가 활성화된 후 maas-default-gateway가 필요
###############################################################################
info "=== Step 3/5: MaaS Gateway 생성 ==="

CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')

# Find TLS cert in openshift-ingress
CERT_NAME=$(oc get secrets -n openshift-ingress --no-headers 2>/dev/null | \
  grep "cert-manager-ingress-cert\|router-certs-default" | awk '{print $1}' | head -1)
if [ -z "$CERT_NAME" ]; then
    warn "TLS 인증서를 찾을 수 없음 — cert-manager-ingress-cert 사용"
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
    success "maas-default-gateway 이미 존재 ✓"
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
    success "maas-default-gateway 생성 완료"
fi
echo ""

###############################################################################
# Step 4. OdhDashboardConfig 패치 — Dashboard 메뉴 전체 활성화
###############################################################################
info "=== Step 4/5: Dashboard 메뉴 전체 활성화 ==="

WAIT=0
while ! oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications &>/dev/null; do
    [ $WAIT -ge 60 ] && { error "OdhDashboardConfig 없음"; exit 1; }
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
      "maasAuthPolicies": true,
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

success "Dashboard 메뉴 패치 완료"
echo ""

###############################################################################
# Step 5. Dashboard 재시작 + 결과 확인
###############################################################################
info "=== Step 5/5: Dashboard 재시작 & 결과 확인 ==="
oc rollout restart deployment/rhods-dashboard -n redhat-ods-applications 2>/dev/null || true
info "재시작 중 (1-2분 소요)..."
sleep 10
oc rollout status deployment/rhods-dashboard -n redhat-ods-applications --timeout=120s 2>/dev/null || \
    warn "롤아웃 타임아웃 — 잠시 후 자동 완료됩니다"
success "Dashboard 재시작 완료"
echo ""

# --- 결과 출력 ---
info "DSC 주요 컴포넌트:"
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
    if [ "${OP_SUB[$i]}" = "rhcl-operator" ]; then
        if oc get csv -A --no-headers 2>/dev/null | grep -q "rhcl-operator.*Succeeded"; then
            echo "  ✅ ${OP_NAMES[$i]}"
        else
            echo "  ⬚  ${OP_NAMES[$i]}"
        fi
    else
        if oc get csv -n "${OP_NS[$i]}" 2>/dev/null | grep -q "${OP_GREP[$i]}.*Succeeded"; then
            echo "  ✅ ${OP_NAMES[$i]}"
        else
            echo "  ⬚  ${OP_NAMES[$i]}"
        fi
    fi
done

echo ""
info "Gateway:"
oc get gateway -n openshift-ingress --no-headers 2>/dev/null | while read name class addr rest; do
    echo "  $name → $addr"
done

echo ""
info "Dashboard URL:"
echo "  https://$(oc get route data-science-gateway -n redhat-ods-applications -o jsonpath='{.spec.host}' 2>/dev/null || echo '(확인 필요)')"

echo ""
echo "=============================================="
success "완료! Dashboard를 새로고침하세요."
echo ""
echo "  ※ MaaS가 NotReady인 경우 DB 설정이 필요합니다:"
echo "    → scripts/setup-maas.sh 또는 install-rhoai-35.sh --setup-maas 실행"
echo "=============================================="
