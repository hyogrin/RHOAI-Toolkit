#!/bin/bash
###############################################################################
# sno-enable-all-features.sh
#
# RHOAI 3.5 SNO(Single Node OpenShift) cluster에서
# DSC component + Dashboard menu를 once enable하는 script
#
# usage:
#   bash sno-enable-all-features.sh
#
# prerequisites:
#   - oc login 
#   - RHOAI 3.5.x Operator installed
#   - DataScienceCluster 'default-dsc' exists
###############################################################################
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }

# Pre-flight checks
echo "=============================================="
echo " RHOAI 3.5 SNO - Enable All Features"
echo "=============================================="
echo ""

if ! oc whoami &>/dev/null; then
    error "oc login이 필요합니다"
    exit 1
fi
info "Cluster: $(oc whoami --show-server)"
info "User: $(oc whoami)"
echo ""

# Check RHOAI version
RHOAI_CSV=$(oc get csv -n redhat-ods-operator --no-headers 2>/dev/null | grep rhods | awk '{print $1}')
if [ -z "$RHOAI_CSV" ]; then
    error "RHOAI Operator가 설치되어 있지 않습니다"
    exit 1
fi
RHOAI_VER=$(echo "$RHOAI_CSV" | sed 's/rhods-operator\.//')
info "RHOAI Version: $RHOAI_VER"

# Check DSC exists
if ! oc get datasciencecluster default-dsc &>/dev/null; then
    error "DataScienceCluster 'default-dsc'가 존재하지 않습니다"
    exit 1
fi
echo ""

###############################################################################
# 1. User Workload Monitoring 활성화
#    GPUaaS Dashboard, Observability가 Prometheus 메트릭을 조회하려면 필수
###############################################################################
info "=== Step 1: User Workload Monitoring 활성화 ==="

if oc get configmap cluster-monitoring-config -n openshift-monitoring &>/dev/null 2>&1; then
    EXISTING=$(oc get configmap cluster-monitoring-config -n openshift-monitoring \
      -o jsonpath='{.data.config\.yaml}' 2>/dev/null)
    if echo "$EXISTING" | grep -q "enableUserWorkload: true"; then
        success "User Workload Monitoring 이미 활성화 ✓"
    else
        warn "cluster-monitoring-config 존재하지만 enableUserWorkload 미설정 — 패치합니다"
        oc apply -f - <<'UWM_EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
UWM_EOF
        success "User Workload Monitoring 활성화 완료"
    fi
else
    info "cluster-monitoring-config 생성 중..."
    oc apply -f - <<'UWM_EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
UWM_EOF
    success "User Workload Monitoring 활성화 완료"
fi

# Wait for user workload monitoring pods
info "User Workload Monitoring pods 대기 중..."
WAIT=0
while [ "$(oc get pods -n openshift-user-workload-monitoring --no-headers 2>/dev/null | grep -c Running)" -lt 2 ]; do
    if [ $WAIT -ge 60 ]; then
        warn "User Workload Monitoring pods 아직 준비되지 않음 (계속 진행)"
        break
    fi
    sleep 5
    WAIT=$((WAIT + 5))
done
oc get pods -n openshift-user-workload-monitoring --no-headers 2>/dev/null | head -5
echo ""

###############################################################################
# 2. DSC 패치 - 백엔드 컴포넌트 활성화
###############################################################################
info "=== Step 2: DSC 컴포넌트 활성화 ==="
info "mlflowoperator: Managed 추가..."

oc patch datasciencecluster default-dsc --type=merge -p '{
  "spec": {
    "components": {
      "mlflowoperator": {
        "managementState": "Managed"
      }
    }
  }
}'

success "DSC 패치 완료"
echo ""

# Verify
sleep 5
MLFLOW_STATE=$(oc get datasciencecluster default-dsc \
  -o jsonpath='{.spec.components.mlflowoperator.managementState}' 2>/dev/null)
if [ "$MLFLOW_STATE" = "Managed" ]; then
    success "mlflowoperator: Managed ✓"
else
    warn "mlflowoperator 상태: $MLFLOW_STATE (Managed가 아님 - Operator 로그 확인 필요)"
fi
echo ""

###############################################################################
# 2. OdhDashboardConfig 패치 - Dashboard 메뉴 전체 활성화
###############################################################################
info "=== Step 3: Dashboard 메뉴 전체 활성화 ==="

# Wait for OdhDashboardConfig to exist
WAIT=0
while ! oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications &>/dev/null; do
    if [ $WAIT -ge 60 ]; then
        error "OdhDashboardConfig를 찾을 수 없습니다 (timeout 60s)"
        exit 1
    fi
    info "OdhDashboardConfig 대기 중... (${WAIT}s)"
    sleep 5
    WAIT=$((WAIT + 5))
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

success "Dashboard 메뉴 패치 완료"
echo ""

###############################################################################
# 3. 결과 확인
###############################################################################
info "=== Step 4: Dashboard 재시작 (모니터링 연동 반영) ==="
oc rollout restart deployment/rhods-dashboard -n redhat-ods-applications 2>/dev/null || true
info "Dashboard 재시작 중 (1-2분 소요)..."
sleep 10
oc rollout status deployment/rhods-dashboard -n redhat-ods-applications --timeout=120s 2>/dev/null || \
    warn "Dashboard 롤아웃 타임아웃 — 잠시 후 자동 완료됩니다"
success "Dashboard 재시작 완료"
echo ""

info "=== Step 5: 결과 확인 ==="
echo ""

# DSC component statuses
info "DSC 컴포넌트 상태:"
oc get datasciencecluster default-dsc -o json 2>/dev/null | python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
conds = data.get('status',{}).get('conditions',[])
for c in sorted(conds, key=lambda x: x.get('type','')):
    t = c.get('type','')
    if t in ('Ready','ProvisioningSucceeded','ComponentsReady','ModulesReady','ProvisioningProgress'):
        continue
    s = c.get('status','')
    icon = '✅' if s == 'True' else '⬚ '
    print(f'  {icon} {t}: {c.get(\"reason\",\"\")}')
" 2>/dev/null

echo ""
info "MLflow CRD 확인:"
if oc get crd mlflows.mlflow.opendatahub.io &>/dev/null 2>&1; then
    success "mlflows.mlflow.opendatahub.io ✓"
else
    warn "MLflow CRD 아직 없음 (Operator 준비 중, 1-2분 대기)"
fi

echo ""
info "MLflow Pod 확인:"
oc get pods -n redhat-ods-applications --no-headers 2>/dev/null | grep -i mlflow || warn "MLflow pod 아직 없음"

echo ""
echo "=============================================="
success "완료! Dashboard를 새로고침하면 모든 메뉴가 표시됩니다."
echo "=============================================="
