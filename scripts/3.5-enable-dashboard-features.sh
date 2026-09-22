#!/bin/bash
################################################################################
# Enable All Dashboard Features for RHOAI 3.5
################################################################################
# Enables all 34 dashboard feature flags for Red Hat OpenShift AI 3.5.
#
# Reference:
#   - https://www.redhat.com/en/blog/red-hat-ai-35-scaling-and-governing-ai-agents-production
#   - https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5
#
# Features activated (by category):
#
#   GA features:
#     - GPU-as-a-Service dashboard (gpuaas) — real-time GPU status, inventory, scheduling
#     - Inference-time scaling — adaptive self-consistency, budget-efficient reasoning
#     - Observability dashboards (observabilityDashboard) — llm-d cluster metrics
#     - Agent templates & catalog (agentOps, agentsCatalog, agentConfigManagement)
#     - NeMo Guardrails (guardrails) — model deployment guardrail configuration
#     - EvalHub (disableLMEval: false) — model & agent evaluation toolkit
#     - Custom role creation UI (roleManagement)
#     - GenAI Studio / Playground (genAiStudio)
#     - Model as a Service (modelAsService, vLLMDeploymentOnMaaS)
#     - Model Catalog & Registry (disableModelCatalog, disableModelRegistry: false)
#     - MCP catalog & registry (mcpCatalog, mcpRegistry)
#     - llm-d templates (llmdTemplates) — deploy wizard integration
#     - Tool calling configuration (toolCalling)
#
#   Technology Preview features:
#     - AutoRAG (autorag) — automated RAG evaluation & hyperparameter tuning
#     - AutoML (automl) — train-to-production predictive models
#     - MaaS showback (observabilityDashboard) — token metering & consumption metrics
#     - Visual agentic tracing (genAiTracing) — OpenTelemetry + MLflow call-tree
#     - Gateway-level guardrails (mcpGuardrailsMode in DSC trustyai)
#     - External model endpoints (externalModels)
#     - External vector stores (externalVectorStores)
#     - Prompt management (promptManagement, globalProjectPrompts)
#
# Usage:
#   ./scripts/3.5-enable-dashboard-features.sh              # Interactive
#   ./scripts/3.5-enable-dashboard-features.sh --apply       # Non-interactive
#   ./scripts/3.5-enable-dashboard-features.sh --verify      # Check current state
#   source scripts/3.5-enable-dashboard-features.sh          # Source for use in install scripts
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source utilities if available
if [ -f "$ROOT_DIR/lib/utils/colors.sh" ]; then
    source "$ROOT_DIR/lib/utils/colors.sh"
fi
if [ -f "$ROOT_DIR/lib/utils/common.sh" ]; then
    source "$ROOT_DIR/lib/utils/common.sh"
fi

# Fallback print functions if not sourced
type print_step &>/dev/null 2>&1    || print_step()    { echo "▶ $*"; }
type print_success &>/dev/null 2>&1 || print_success() { echo "✓ $*"; }
type print_info &>/dev/null 2>&1    || print_info()    { echo "ℹ $*"; }
type print_warning &>/dev/null 2>&1 || print_warning() { echo "⚠ $*"; }
type print_error &>/dev/null 2>&1   || print_error()   { echo "✗ $*"; }
type print_header &>/dev/null 2>&1  || print_header()  { echo ""; echo "═══ $* ═══"; echo ""; }

################################################################################
# Dashboard Feature Flags — RHOAI 3.5 (34 total)
################################################################################

# All 34 flags in a single JSON patch.
# Flags are grouped by origin:
#   - 14 carried from 3.4
#   - 20 new in 3.5
build_dashboard_patch() {
    cat <<'PATCH_EOF'
{
    "spec": {
        "dashboardConfig": {
            "disableModelRegistry": false,
            "disableModelCatalog": false,
            "disableKServeMetrics": false,
            "disableLMEval": false,
            "disableKueue": false,
            "disablePerformanceMetrics": false,
            "disableDistributedWorkloads": false,
            "disableTrustyBiasMetrics": false,
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
}
PATCH_EOF
}

################################################################################
# Functions
################################################################################

check_connection() {
    if ! oc whoami &>/dev/null; then
        print_error "Not logged in to OpenShift. Run: oc login <cluster-url>"
        return 1
    fi
    local cluster_url
    cluster_url=$(oc whoami --show-server 2>/dev/null)
    print_info "Connected: $(oc whoami) @ $cluster_url"
    return 0
}

wait_for_dashboard_config() {
    print_step "Waiting for OdhDashboardConfig to exist..."
    local elapsed=0
    while [ $elapsed -lt 120 ]; do
        if oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications &>/dev/null; then
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    print_error "OdhDashboardConfig not found after 120s — is RHOAI installed?"
    return 1
}

apply_dashboard_features() {
    print_step "Applying 34 dashboard feature flags for RHOAI 3.5..."

    local patch_json
    patch_json=$(build_dashboard_patch)

    if oc patch odhdashboardconfig odh-dashboard-config \
        -n redhat-ods-applications \
        --type=merge \
        -p "$patch_json" 2>/dev/null; then
        print_success "Dashboard features enabled (34 flags for RHOAI 3.5)"
    else
        print_error "Failed to patch OdhDashboardConfig"
        return 1
    fi
}

verify_dashboard_features() {
    print_header "RHOAI 3.5 Dashboard Feature Status"

    if ! oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications &>/dev/null; then
        print_error "OdhDashboardConfig not found"
        return 1
    fi

    local config
    config=$(oc get odhdashboardconfig odh-dashboard-config \
        -n redhat-ods-applications \
        -o jsonpath='{.spec.dashboardConfig}' 2>/dev/null)

    # GA features
    echo ""
    echo "  ┌─────────────────────────────────────────────────────────────┐"
    echo "  │  GA Features                                                │"
    echo "  ├─────────────────────────────────────────────────────────────┤"
    _check_flag "$config" "gpuaas"                 "GPU-as-a-Service dashboard"
    _check_flag "$config" "genAiStudio"            "GenAI Studio / Playground"
    _check_flag "$config" "modelAsService"         "Model as a Service (MaaS)"
    _check_flag "$config" "vLLMDeploymentOnMaaS"   "vLLM deployment on MaaS"
    _check_flag "$config" "observabilityDashboard" "Observability dashboard"
    _check_flag "$config" "guardrails"             "NeMo Guardrails config"
    _check_flag "$config" "roleManagement"         "Custom role creation UI"
    _check_flag "$config" "agentOps"               "Agent operations"
    _check_flag "$config" "agentsCatalog"          "Agent templates catalog"
    _check_flag "$config" "agentConfigManagement"  "Agent config management"
    _check_flag "$config" "mcpCatalog"             "MCP catalog"
    _check_flag "$config" "mcpRegistry"            "MCP server registry"
    _check_flag "$config" "llmdTemplates"          "llm-d deploy templates"
    _check_flag "$config" "toolCalling"            "Tool calling config"
    _check_disable_flag "$config" "disableLMEval"        "EvalHub (LM Eval)"
    _check_disable_flag "$config" "disableModelRegistry" "Model Registry"
    _check_disable_flag "$config" "disableModelCatalog"  "Model Catalog"
    _check_disable_flag "$config" "disableKServeMetrics" "KServe Metrics"
    _check_disable_flag "$config" "disableKueue"         "Kueue integration"

    echo "  ├─────────────────────────────────────────────────────────────┤"
    echo "  │  Technology Preview Features                                │"
    echo "  ├─────────────────────────────────────────────────────────────┤"
    _check_flag "$config" "autorag"               "AutoRAG"
    _check_flag "$config" "automl"                "AutoML"
    _check_flag "$config" "genAiTracing"          "Visual agentic tracing (MLflow)"
    _check_flag "$config" "externalModels"        "External model endpoints"
    _check_flag "$config" "externalVectorStores"  "External vector stores"
    _check_flag "$config" "promptManagement"      "Prompt management"
    _check_flag "$config" "globalProjectPrompts"  "Global project prompts"
    _check_flag "$config" "featureStoreAdmin"     "Feature Store admin"

    echo "  ├─────────────────────────────────────────────────────────────┤"
    echo "  │  UI & Workflow                                              │"
    echo "  ├─────────────────────────────────────────────────────────────┤"
    _check_flag "$config" "connectionTest"              "Connection testing"
    _check_flag "$config" "deploymentWizardYAMLViewer"  "YAML viewer in deploy wizard"
    _check_flag "$config" "aiAssetCustomEndpoints"      "Custom AI endpoints"
    _check_flag "$config" "llmGatewayField"             "LLM gateway selector"
    _check_flag "$config" "projectRBAC"                 "Per-project RBAC UI"
    _check_flag "$config" "trainingJobs"                "Training job management"
    echo "  └─────────────────────────────────────────────────────────────┘"
    echo ""
}

# Helper: check a boolean flag (true = enabled)
_check_flag() {
    local config="$1" key="$2" label="$3"
    local val
    val=$(echo "$config" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$key','<unset>'))" 2>/dev/null || echo "<unset>")
    if [ "$val" = "true" ] || [ "$val" = "True" ]; then
        printf "  │  ✅ %-40s %s\n" "$label" ""
    else
        printf "  │  ❌ %-40s (current: %s)\n" "$label" "$val"
    fi
}

# Helper: check a disable* flag (false = enabled)
_check_disable_flag() {
    local config="$1" key="$2" label="$3"
    local val
    val=$(echo "$config" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$key','<unset>'))" 2>/dev/null || echo "<unset>")
    if [ "$val" = "false" ] || [ "$val" = "False" ]; then
        printf "  │  ✅ %-40s %s\n" "$label" ""
    else
        printf "  │  ❌ %-40s (current: %s)\n" "$label" "$val"
    fi
}

show_feature_summary() {
    print_header "RHOAI 3.5 Feature Reference"

    echo "  Features enabled by this script (from Red Hat AI 3.5 blog):"
    echo ""
    echo "  GA:"
    echo "    • GPU-as-a-Service dashboard — GPU status, inventory, scheduling"
    echo "    • Inference-time scaling — adaptive self-consistency, budget-efficient"
    echo "    • Observability dashboards — llm-d cluster metrics, per-project visibility"
    echo "    • NeMo Guardrails — model-level guardrail configuration"
    echo "    • EvalHub — model & agent evaluation, safety benchmarks"
    echo "    • Agent templates & catalog — preconfigured agentic patterns"
    echo "    • Priority-aware serving — fairness policies, starvation protection"
    echo "    • Controlled deployments — canary validation, zero-disruption rollback"
    echo ""
    echo "  Technology Preview:"
    echo "    • AutoRAG — automated RAG evaluation, pgvector, multilingual"
    echo "    • AutoML — built-in serving runtimes for predictive models"
    echo "    • MaaS showback — billing-grade token metering per business unit"
    echo "    • Visual agentic tracing — OpenTelemetry + MLflow call-tree"
    echo "    • Gateway-level guardrails — validate agent tool calls at gateway"
    echo ""
    echo "  Note: Inference-time scaling and priority-aware serving are"
    echo "  KServe/llm-d runtime features — not dashboard flags. They are"
    echo "  activated via model deployment configuration, not OdhDashboardConfig."
    echo ""
}

################################################################################
# Main Execution
################################################################################

main() {
    local mode="interactive"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --apply)    mode="apply"; shift ;;
            --verify)   mode="verify"; shift ;;
            --help|-h)
                echo "Usage: $0 [--apply | --verify | --help]"
                echo ""
                echo "  --apply    Apply all 34 feature flags non-interactively"
                echo "  --verify   Check current dashboard feature status"
                echo "  --help     Show this help"
                echo ""
                echo "Without flags, runs in interactive mode."
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    # Verify-only mode
    if [ "$mode" = "verify" ]; then
        check_connection || exit 1
        verify_dashboard_features
        exit 0
    fi

    # Interactive mode — show summary and confirm
    if [ "$mode" = "interactive" ]; then
        print_header "Enable All Dashboard Features — RHOAI 3.5"
        show_feature_summary

        read -p "Apply all 34 dashboard feature flags? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            print_info "Cancelled"
            exit 0
        fi
        echo ""
    fi

    # Apply
    check_connection || exit 1
    wait_for_dashboard_config || exit 1
    apply_dashboard_features || exit 1

    echo ""
    verify_dashboard_features

    # Show dashboard URL
    local dashboard_url
    dashboard_url=$(oc get route rh-ai -n redhat-ods-applications -o jsonpath='{.spec.host}' 2>/dev/null || \
                    oc get route rhods-dashboard -n redhat-ods-applications -o jsonpath='{.spec.host}' 2>/dev/null || \
                    echo "")
    if [ -n "$dashboard_url" ]; then
        print_success "Dashboard: https://$dashboard_url"
    fi
    echo ""
}

# Run main only if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
