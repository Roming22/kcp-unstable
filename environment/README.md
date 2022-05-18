## Goal
Contains the information necessary to initialize the KCP and Pipeline Service clusters  for a
single environment by:

- creating the necessary namespaces, sa on both KCP and Pipeline Service clusters
- registering the clusters to the right ArgoCD instance

This repo allows to do the minimum work required to hand over a KCP to a workspace
admin so they can register the cluster to their KCP workspace.

## Structure
This repository would hold the following files:
- `kcp`: Config files to link the kcp cluster to ArgoCD instance(s).
  The generic resources to connect the cluster to a pipeline service cluster are created.
- `compute/{cluster_name}`: Config files to link the pipeline service cluster(s)
  to ArgoCD instance(s). The generic resources to connect the cluster to a KCP cluster are
  created.

Both these folder follow a rigid structure composed of:
- `config`: Folder to hold the yaml(s) describing the configuration. For large configurations
  it may make sense to split the configuration in smaller units.
- `gitops/[kcp|compute].yaml`: The manifest for the ArgoCD application
- `gitops/overlay/kustomization.yaml`: The kustomization to be applied to the standard
  resource before deploying it on the ArgoCD cluster.
