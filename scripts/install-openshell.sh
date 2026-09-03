#!/bin/bash
################################################################################
# OpenShell Installation Script
# Installs NVIDIA OpenShell on OpenShift for secure AI agent sandboxing
#
# OpenShell provides kernel-enforced isolation for AI agent code execution:
#   - Landlock filesystem restrictions
#   - seccomp system call filtering
#   - Network namespace isolation
#   - Per-binary OPA/Rego network policy
#   - L7 HTTP inspection via TLS interception
#
# Prerequisites:
#   - OpenShift 4.x cluster with cluster-admin
#   - helm CLI installed
#   - oc CLI logged into the cluster
#
# References:
#   - https://github.com/NVIDIA/OpenShell
#   - https://docs.nvidia.com/openshell/latest/kubernetes/openshift
#   - https://www.redhat.com/en/blog/red-hat-ai-and-openshell-driving-security-enhanced-agent-execution-for-enterprise-ai
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$REPO_ROOT/lib/utils/colors.sh" 2>/dev/null || true

NAMESPACE="${OPENSHELL_NAMESPACE:-openshell}"
CHART_REPO="oci://ghcr.io/nvidia/openshell/helm-chart"
CHART_VERSION="${OPENSHELL_VERSION:-}"
SANDBOX_SA="openshell-sandbox"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install or uninstall NVIDIA OpenShell on OpenShift.

Options:
    -n, --namespace NAME    Namespace to install into (default: openshell)
    -v, --version VERSION   Helm chart version (default: latest)
    --uninstall             Uninstall OpenShell
    --status                Show OpenShell status
    -h, --help              Show this help

Environment Variables:
    OPENSHELL_NAMESPACE     Override default namespace
    OPENSHELL_VERSION       Override default chart version

Examples:
    $(basename "$0")                    # Install with defaults
    $(basename "$0") -v 0.6.0           # Install specific version
    $(basename "$0") --status           # Check status
    $(basename "$0") --uninstall        # Uninstall
EOF
    exit 0
}

check_prerequisites() {
    echo_info "Checking prerequisites..."

    if ! command -v oc &>/dev/null; then
        echo_error "oc CLI not found. Please install it first."
        exit 1
    fi

    if ! oc whoami &>/dev/null; then
        echo_error "Not logged into OpenShift cluster. Run 'oc login' first."
        exit 1
    fi

    if ! command -v helm &>/dev/null; then
        echo_warn "helm CLI not found. Installing via brew..."
        if command -v brew &>/dev/null; then
            brew install helm
        else
            echo_error "helm CLI not found and brew is not available. Install helm manually:"
            echo "  https://helm.sh/docs/intro/install/"
            exit 1
        fi
    fi

    echo_info "Prerequisites OK"
}

install_openshell() {
    echo_info "Installing OpenShell into namespace: $NAMESPACE"

    # 1. Create namespace
    if oc get ns "$NAMESPACE" &>/dev/null; then
        echo_info "Namespace '$NAMESPACE' already exists"
    else
        echo_info "Creating namespace '$NAMESPACE'..."
        oc create ns "$NAMESPACE"
    fi

    # 2. Grant privileged SCC to sandbox service account
    echo_info "Granting privileged SCC to '$SANDBOX_SA' service account..."
    oc adm policy add-scc-to-user privileged -z "$SANDBOX_SA" -n "$NAMESPACE"

    # 3. Install via Helm
    local helm_args=(
        install openshell "$CHART_REPO"
        -n "$NAMESPACE"
        --set server.disableTls=true
        --set podSecurityContext.fsGroup=null
        --set securityContext.runAsUser=null
    )

    if [[ -n "$CHART_VERSION" ]]; then
        helm_args+=(--version "$CHART_VERSION")
    fi

    if helm status openshell -n "$NAMESPACE" &>/dev/null; then
        echo_warn "OpenShell is already installed. Upgrading..."
        helm_args[0]="upgrade"
    fi

    echo_info "Running: helm ${helm_args[*]}"
    helm "${helm_args[@]}"

    # 4. Wait for pod readiness
    echo_info "Waiting for OpenShell pod to be ready..."
    oc rollout status statefulset/openshell -n "$NAMESPACE" --timeout=120s 2>/dev/null || \
    oc rollout status deployment/openshell -n "$NAMESPACE" --timeout=120s 2>/dev/null || true

    echo ""
    show_status
    echo ""
    echo_info "OpenShell installation complete!"
    echo_info "Gateway endpoint: http://openshell.${NAMESPACE}.svc.cluster.local:8080"
}

uninstall_openshell() {
    echo_warn "Uninstalling OpenShell from namespace: $NAMESPACE"

    if helm status openshell -n "$NAMESPACE" &>/dev/null; then
        helm uninstall openshell -n "$NAMESPACE"
        echo_info "Helm release removed"
    else
        echo_warn "No Helm release 'openshell' found in namespace '$NAMESPACE'"
    fi

    echo_info "Removing SCC binding..."
    oc adm policy remove-scc-from-user privileged -z "$SANDBOX_SA" -n "$NAMESPACE" 2>/dev/null || true

    read -rp "Delete namespace '$NAMESPACE'? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        oc delete ns "$NAMESPACE" --wait=false
        echo_info "Namespace deletion initiated"
    fi

    echo_info "OpenShell uninstalled"
}

show_status() {
    echo_info "=== OpenShell Status ==="
    echo ""

    if ! oc get ns "$NAMESPACE" &>/dev/null; then
        echo_warn "Namespace '$NAMESPACE' does not exist. OpenShell is not installed."
        return 1
    fi

    echo "--- Helm Release ---"
    helm list -n "$NAMESPACE" 2>/dev/null || echo "  (no helm release found)"
    echo ""

    echo "--- Pods ---"
    oc get pods -n "$NAMESPACE" 2>/dev/null
    echo ""

    echo "--- Services ---"
    oc get svc -n "$NAMESPACE" 2>/dev/null
    echo ""

    echo "--- Sandbox Pods ---"
    local sandbox_count
    sandbox_count=$(oc get pods -n "$NAMESPACE" -l openshell.dev/sandbox-id --no-headers 2>/dev/null | wc -l | tr -d ' ')
    echo "  Active sandboxes: $sandbox_count"
}

# --- Parse arguments ---
ACTION="install"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--namespace) NAMESPACE="$2"; shift 2 ;;
        -v|--version)   CHART_VERSION="$2"; shift 2 ;;
        --uninstall)    ACTION="uninstall"; shift ;;
        --status)       ACTION="status"; shift ;;
        -h|--help)      usage ;;
        *) echo_error "Unknown option: $1"; usage ;;
    esac
done

# --- Main ---
case "$ACTION" in
    install)
        check_prerequisites
        install_openshell
        ;;
    uninstall)
        check_prerequisites
        uninstall_openshell
        ;;
    status)
        show_status
        ;;
esac
