## Goal
Contains the information necessary to link KCP workspaces to plnsvc clusters by:

- creating the necessary resources on the KCP and plnsvc clusters
- deploying the controllers

## Structure
This repository would hold the following files:
- kubeconfig/kcp: kubeconfig for the various KCP instances for which we provide Pipeline Service
  clusters.
- kubeconfig/plnsvc: kubeconfig for the various Pipeline Service clusters under our responsibility.
- environments/{env_name}: Config files are aggregated per environment to facilitate navigating
  the repository
- tenants/{tenant_name}: Config files are aggregated per tenant to facilitate navigating
  the repository. The config files describe the links between the kcp cluster(s) and the \
  plnsvc instance(s). Controllers will be deployed to the clusters. Files under this directory \
  can be organized anyway the repository owners want to (here we decided to group them per
  workspace).
