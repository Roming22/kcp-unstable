#!/bin/sh
SCRIPT_DIR="$(cd "$(dirname "$0")" >/dev/null; pwd)"

INFRA_DIR="$HOME/Code/appStudio/infra/infra"
CREDS_DIR="$SCRIPT_DIR/credentials/kubeconfig"

# Login
"$INFRA_DIR/login.sh" -e staging

# Copy credentials
cp "$INFRA_DIR/work/kubeconfig/argocd.yaml" "$CREDS_DIR/argocd/stg.3jhu.p1.yaml"
cp "$INFRA_DIR/work/kubeconfig/kcp.yaml" "$CREDS_DIR/kcp/kcp-unstable.yaml"
sed -i -e "s/: kcp-unstable/: unstable/g" "$CREDS_DIR/kcp/kcp-unstable.yaml"
cp "$INFRA_DIR/work/kubeconfig/plnsvc.yaml" "$CREDS_DIR/plnsvc/stg.3jhu.p1.yaml"
