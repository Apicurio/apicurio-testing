# Apicurio QE GitHub Actions Workflows

## Release Workflow Overview

There is a single "entry point" workflow for testing releases, located at `.github/workflows/test-regsitry-release.yml`.
It uses matrix strategies and the `workflow_call` feature of GitHub Actions to call and reuse other sub-workflows.

The workflow graph is as follows:

<style>
    :root ol { list-style-type: decimal; }
</style>

1. Entry point in `test-registry-release.yml`
    1. Cluster matrix (OKD 4.19, OKD 4.14) with cluster-specific tests in `clusters.yaml`:
        1. Basic SQL storage matrix (in-memory, MySQL) with tests in `sql-storage-basic.yaml`
            1. UI tests
            2. Integration tests