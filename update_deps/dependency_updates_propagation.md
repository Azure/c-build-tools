# Dependency Updates Propagation

## build_graph.ps1

This script takes as argument the URL of the repository upto which updates must be propagated.\\
It builds the dependency graph and performs bottom-up level-order traversal to determine the order in which \\
the submodules must be updates such that all submodules contain the latest changes.

### Usage

```
PS> .\build_graph.ps1 [repo_url]
```
## propagate_updates.ps1

Given a root repo and personal access tokens for Github and Azure Devops Services, this script \
builds the dependency graph and propagates updates from the lowest level upto the \
root repo by making PRs to each repo in bottom-up level-order.

### Usage

Run the script in a clean directory:

```
PS> .\{PATH_TO_SCRIPT}\propagate_updates.ps1 -azure_token {token1} -github_token {token2} [-azure_work_item {work_item_id}] [-root {root_repo_url}] 
```
### Arguments:

- `-azure_token`: Mandatory. Personal access token for Azure Devops Services. Token must have permissions for Code and Work Items.
- `-github_token`: Mandatory. Personal access token for Github. Token must be authorized for use with the Azure organization on Github.
- `-azure_work_item`: Optional. Work item id of Azure work item that is linked to PRs made to Azure repos. Only required if Azure repos need to be updated.
- `-root`: Optional. URL of the repository upto which updates must be propagated. [Azure-MessagingStore](https://msazure.visualstudio.com/DefaultCollection/One/_git/Azure-MessagingStore) by default.


### ignores.json

`ignores.json` contains a list of repositories that should be ignored while building the dependency graph and should not be updated.
