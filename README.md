## Structure
The `argocd` and `workspaces` would be 2 different gitops repositories. Nothing prevents
them from being consolidated in a single repository in cases where it makes sense.

The `git_actions` contains scripts that would be executed when the gitops repositories are
modified. Those scripts could be put in images on quay.io to be easy to run from anywhere.

Each folder has its own README.md with further details.

Ignore the `login.sh` at the root, it's there because it's useful to me when testing.