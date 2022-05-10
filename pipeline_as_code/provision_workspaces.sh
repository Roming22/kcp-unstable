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

Setup the pipeline service clusters, register the KCP an pipeline service clusters to
ArgoCD.

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

    kubeconfig_kcp_plnsvc="$WORK_DIR/kubeconfig/kcp.plnsvc-manager.yaml"
    mkdir -p "$(dirname "$kubeconfig_kcp_plnsvc")"
    credentials_dir="$(dirname "$SCRIPT_DIR")/credentials"
}

argocd_env() {
    argocd --config "$KUBECONFIG_ARGOCD" "$@"
}

kcp_config() {
    KUBECONFIG="$kubeconfig_kcp" "$@"
}

plnsvc_config() {
    KUBECONFIG="$kubeconfig_plnsvc" "$@"
}

use_kcp_workspace() {
    kcp_config kubectl kcp workspace use "$tenant_id" >/dev/null
    kcp_config kubectl kcp workspace use "$1" >/dev/null
}

process_tenant() {
    tenant_name="$(basename "$tenant_dir")"
    echo "[$tenant_name]"
    configs="$(find "$tenant_dir" -name \*.yaml)"
    for config in $configs; do
        process_config
    done
}

process_config() {
    kcp_name="$(yq ".kcp-cluster" "$config")"
    kubeconfig_kcp="$credentials_dir/kcp/$kcp_name.yaml"
    tenant_id="$(yq ".clusters[0].cluster.server" "$kubeconfig_kcp" | sed "s:.*/::" | cut -d: -f1,2)"

    workspace_count="$(yq ".workspaces | length" "$config")"
    for w_id in $(seq 0 $((workspace_count - 1))); do
        process_workspace
    done
}

process_workspace() {
    workspace_name="$(yq ".workspaces[$w_id].name" "$config")"
    echo "    - $workspace_name"

    workspace_id="$tenant_id:$workspace_name"
    use_kcp_workspace "$workspace_id"
    cluster_count="$(yq ".workspaces[$w_id].plnsvc-clusters | length" "$config")"
    for c_id in $(seq 0 $((cluster_count - 1))); do
        plnsvc_name="$(yq ".workspaces[$w_id].plnsvc-clusters[$c_id].name" "$config")"
        kubeconfig_plnsvc="$credentials_dir/plnsvc/$plnsvc_name.yaml"
        echo "        - pipeline service cluster: $plnsvc_name ($((c_id + 1))/$cluster_count)"
        setup_kcp_cluster
        setup_plnsvc_cluster
        setup_argocd_applications
    done
}

setup_kcp_cluster() {
    if [ "$c_id" == "0" ]; then
        get_context kcp_config "$kcp_name-plnsvc" plnsvc plnsvc-manager "$kubeconfig_kcp_plnsvc"
    fi

    echo -n "            - Create workloadcluster on KCP '$kcp_name' cluster: "
    local manifests_dir="$WORK_DIR/manifests"
    mkdir -p "$manifests_dir/plnsvc"
    if ! kcp_config kubectl get workloadcluster plnsvc >/dev/null 2>&1; then
        kcp_config kubectl kcp workload sync plnsvc --kcp-namespace plnsvc \
            --resources pods,services \
            --syncer-image ghcr.io/kcp-dev/kcp/syncer-c2e3073d5026a8f7f2c47a50c16bdbec:41ca72b >"$manifests_dir/plnsvc/kcp-syncer.yaml"
    fi
    echo "OK"

    echo "            - Create secrets:"
    kcp_config kubectl create secret generic kcp-kubeconfig --from-file "$kubeconfig_kcp_plnsvc" \
        --dry-run=client -o yaml |
        sed "s%^  $(basename "$kubeconfig_kcp_plnsvc"): %  admin.kubeconfig: %" |
        kcp_config kubectl apply -f -
    kcp_config kubectl create secret generic kcp-kubeconfig -n tekton-pipelines \
        --from-file "$kubeconfig_kcp_plnsvc" --dry-run=client -o yaml |
        sed "s%^  $(basename "$kubeconfig_kcp_plnsvc"): %  admin.kubeconfig: %" |
        kcp_config kubectl apply -f -
}

setup_plnsvc_cluster() {
    echo -n "            - Register plnsvc '$plnsvc_name' cluster to KCP: "
    if [ -f "$WORK_DIR/manifests/plnsvc/kcp-syncer.yaml" ]; then
        echo
        plnsvc_config kubectl apply -f "$WORK_DIR/manifests/plnsvc/kcp-syncer.yaml"
    else
        echo "OK"
    fi

    echo "                - Create secrets:"
    plnsvc_config kubectl create secret generic kcp-kubeconfig -n pipelines \
        --from-file "$kubeconfig_kcp_plnsvc" --dry-run=client -o yaml |
        sed "s%^  $(basename "$kubeconfig_kcp_plnsvc"): %  admin.kubeconfig: %" |
        plnsvc_config kubectl apply -f -
    plnsvc_config kubectl create secret generic kcp-kubeconfig -n triggers \
        --from-file "$kubeconfig_kcp_plnsvc" --dry-run=client -o yaml |
        sed "s%^  $(basename "$kubeconfig_kcp_plnsvc"): %  admin.kubeconfig: %" |
        plnsvc_config kubectl apply -f -
}

setup_argocd_applications() {
    echo "                - Create ArgoCD applications:"
    # TODO: Deploy the operators using kustomize
    for app in pipelines-crds triggers-crds triggers-interceptors; do
        curl --silent --fail -o "$WORK_DIR/manifests/plnsvc/$app.yaml" "https://raw.githubusercontent.com/openshift-pipelines/pipelines-service/main/gitops/$app.yaml"
        yq -e -i ".spec.destination.name=\"kcp.$kcp_name\"" "$WORK_DIR/manifests/plnsvc/$app.yaml"
        yq -e -i ".metadata.name=\"${kcp_name}.${tenant_name}.${workspace_name}.$app\"" "$WORK_DIR/manifests/plnsvc/$app.yaml"
        plnsvc_config kubectl apply -f "$WORK_DIR/manifests/plnsvc/$app.yaml"
    done
    for app in pipelines-controller triggers-controller; do
        curl --silent --fail -o "$WORK_DIR/manifests/plnsvc/$app.yaml" "https://raw.githubusercontent.com/openshift-pipelines/pipelines-service/main/gitops/$app.yaml"
        yq -e -i ".spec.destination.name=\"plnsvc.$plnsvc_name\"" "$WORK_DIR/manifests/plnsvc/$app.yaml"
        yq -e -i ".metadata.name=\"${kcp_name}.${tenant_name}.${workspace_name}.$app\"" "$WORK_DIR/manifests/plnsvc/$app.yaml"
        plnsvc_config kubectl apply -f "$WORK_DIR/manifests/plnsvc/$app.yaml"
    done
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
        cd "$SCRIPT_DIR/../workspaces" >/dev/null
        pwd
    )"
    find "$repository_dir/tenants" -mindepth 1 -maxdepth 1 -type d | while read -r tenant_dir; do
        process_tenant
    done
}

if [ "${BASH_SOURCE[0]}" == "$0" ]; then
    main "$@"
fi
