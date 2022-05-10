#!/usr/bin/env bash

# Copyright 2022 The pipelines-service Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null
    pwd
)"

usage() {
    echo "
Usage:
    ${0##*/} [options]

Connect the KCP and pipeline service clusters to ArgoCD, and deploy the required
resources to provide the service. The pipeline service clusters are then ready
to be registered to KCP workspaces.

Optional arguments:
    -d, --debug
            Activate tracing/debug mode.
    -h, --help
            Display this message.

Example:
    ${0##*/} -d
" >&2
}

parse_args() {
    local args
    args="$(getopt -o dh -l "debug,help" -n "$0" -- "$@")"
    eval set -- "$args"
    while true; do
        case "$1" in
        -d | --debug)
            set -x
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        --)
            # End of arguments
            break
            ;;
        *)
            echo "Unknown argument: $1"
            usage
            exit 1
            ;;
        esac
        shift
    done
}

init() {
    WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/work}"
    mkdir -p "$WORK_DIR"

    credentials_dir="$(dirname "$SCRIPT_DIR")/credentials"
    plnsvc_version="main"
    plnsvc_url="https://raw.githubusercontent.com/openshift-pipelines/pipelines-service/$plnsvc_version"
    plnsvc_url="https://raw.githubusercontent.com/roming22/pipelines-service/my/gitops"
}

argocd_env() {
    argocd --config "$kubeconfig_argocd" "$@"
}

kcp_config() {
    KUBECONFIG="$kubeconfig_kcp" "$@"
}

plnsvc_config() {
    KUBECONFIG="$kubeconfig_plnsvc" "$@"
}

use_kcp_workspace() {
    kcp_config kubectl kcp workspace use "root:$tenant_id" >/dev/null
    kcp_config kubectl kcp workspace use "$workspace_name" >/dev/null
}

process_env() {
    echo "[Environment]"

    # Provision KCP cluster(s)
    configs="$(find "$repository_dir/kcp/config" -mindepth 1 -name \*yaml | sort)"
    for config in $configs; do
        setup_kcp
    done

    # Provision Pipeline Service cluster(s)
    configs="$(find "$repository_dir/plnsvc" -mindepth 2 -maxdepth 2 -name config.yaml | sort)"
    for config in $configs; do
        setup_plnsvc
    done
}

set_cluster_env() {
        argocd_name="$(yq ".argocd-cluster" "$config")"
        kubeconfig_argocd="$credentials_dir/kubeconfig/argocd/$argocd_name.yaml"
        gitops_dir="$(cd "$(dirname "$config")/../gitops" >/dev/null; pwd)"
}

setup_kcp(){
    set_cluster_env
    cluster_count="$(yq ".kcp-clusters | length" "$config")"
    for c_id in $(seq 0 $((cluster_count - 1))); do
        setup_kcp_cluster
    done
}

setup_kcp_cluster() {
    cluster_name="$(yq ".kcp-clusters[$c_id].name" "$config")"
    echo "    - KCP cluster: $cluster_name"

    kubeconfig_kcp="$credentials_dir/kubeconfig/kcp/$cluster_name.yaml"
    tenant_count="$(yq ".kcp-clusters[$c_id].tenants | length" "$config")"
    for t_id in $(seq 0 $((tenant_count - 1))); do
        setup_kcp_tenant
    done

    echo
}

setup_kcp_tenant() {
    tenant_name="$(yq ".kcp-clusters[$c_id].tenants[$t_id].name" "$config")"
    tenant_id="$(yq ".kcp-clusters[$c_id].tenants[$t_id].id" "$config")"
    echo "        - Tenant: $tenant_name"
    workspace_count="$(yq ".kcp-clusters[$c_id].tenants[$t_id].workspaces | length" "$config")"
    for w_id in $(seq 0 $((workspace_count - 1))); do
        setup_kcp_workspace
    done
}

setup_kcp_workspace() {
    workspace_name="$(yq ".kcp-clusters[$c_id].tenants[$t_id].workspaces[$w_id].name" "$config")"

    echo "            - Workspace: $workspace_name"
    use_kcp_workspace

    kubeconfig_kcp_argocd="$credentials_dir/kubeconfig/kcp/kcp.argocd-manager.yaml"

    echo "                - Service account for connecting KCP to ArgoCD:"
    kcp_config kubectl apply -f "$plnsvc_url/kcp/manifests/kcp/argocd-manager.yaml"
    get_context kcp_config "${cluster_name}-argocd" kube-system argocd-manager "$kubeconfig_kcp_argocd"

    echo -n "            - Register KCP workspace to ArgoCD as '$cluster_name': "
    KUBECONFIG="$kubeconfig_kcp_argocd" argocd_env cluster add "${cluster_name}-argocd" \
        --name="kcp.$cluster_name" --service-account argocd-manager --upsert --yes >/dev/null
    echo "OK"

    echo "            - Setup the ArgoCD application:"
    argocd_env app create -f "$gitops_dir/kcp.yaml"
}

setup_plnsvc(){
    set_cluster_env
    cluster_count="$(yq ".plnsvc-clusters | length" "$config")"
    for c_id in $(seq 0 $((cluster_count - 1))); do
        setup_plnsvc_cluster
    done
}

setup_plnsvc_cluster() {
    cluster_name="$(yq ".plnsvc-clusters[$c_id].name" "$config")"
    echo "    - Pipeline cluster: $cluster_name"

    kubeconfig_plnsvc="$credentials_dir/kubeconfig/plnsvc/$cluster_name.yaml"

    echo "            - Service account for connecting the plnsvc cluster to ArgoCD: "
    plnsvc_config kubectl apply -f "$plnsvc_url/kcp/manifests/plnsvc/argocd-manager.yaml"

    echo -n "            - Register cluster to ArgoCD as '$cluster_name': "
    KUBECONFIG="$kubeconfig_plnsvc" argocd_env cluster add \
        "$(yq ".current-context" <"$kubeconfig_plnsvc")" \
        --service-account argocd-manager --name="plnsvc.$cluster_name" --upsert --yes >/dev/null
    echo "OK"

    echo "            - Setup the ArgoCD application:"
    argocd_env app create -f "$gitops_dir/plnsvc.yaml"

    echo
}

get_context() {
    # Helper function to generate a kubeconfig file for a service account
    local cluster_config="$1"
    local sa_context="$2"
    local namespace="$3"
    local sa="$4"
    local target="$5"
    local current_context
    current_context="$($cluster_config kubectl config current-context)"

    if ! which jq &>/dev/null; then
        echo "[ERROR] Install jq"
        exit 1
    fi
    mkdir -p "$(dirname "$target")"
    token_secret="$($cluster_config kubectl get sa "$sa" -n "$namespace" -o json |
        jq -r '.secrets[].name | select(. | test(".*token.*"))')"
    current_cluster="$($cluster_config kubectl config view \
        -o jsonpath="{.contexts[?(@.name==\"$current_context\")].context.cluster}")"

    $cluster_config kubectl config set-credentials "$sa" --token="$(
        $cluster_config kubectl get secret "$token_secret" -n "$namespace" -o jsonpath="{.data.token}" |
            base64 -d
    )" &>/dev/null
    $cluster_config kubectl config set-context "$sa_context" --user="$sa" --cluster="$current_cluster" &>/dev/null
    $cluster_config kubectl config use-context "$sa_context" &>/dev/null
    $cluster_config kubectl config view --flatten --minify >"$target"
    $cluster_config kubectl config use-context "$current_context" &>/dev/null
}

main() {
    parse_args "$@"
    init
    repository_dir="$(
        cd "$SCRIPT_DIR/../environment" >/dev/null
        pwd
    )"
    process_env
}

if [ "${BASH_SOURCE[0]}" == "$0" ]; then
    main "$@"
fi
