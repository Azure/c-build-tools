# Dependency Updates Propagation

## build_graph.ps1

This script takes as argument the URL of the repository upto which updates must be propagated.\\
It builds the dependency graph and performs bottom-up level-order traversal to determine the order in which \\
the submodules must be updates such that all submodules contain the latest changes.

### Usage

```
PS> .\build_graph.ps1 [repo_url]
```
# propagate_updates.ps1

[TODO]


