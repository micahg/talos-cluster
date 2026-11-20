# Plan: environment values and version pins live in talos-cluster

Decided 2026-11-19. Replaces the earlier idea of a `prod` tag in tbltp that CI moves.

## Goal

- Per-environment values and image pins for tbltp and cobblepod live in this repo
  (`envs/<env>/<app>.yaml`), not in the app repos. App repo history stays free of deploy commits.
- App repos' CI bumps the pins here through a self-merging PR (dev: on release; prod: after the
  `Prod` environment is approved). CI never touches the clusters.
- Prod pins the chart to a released tag (`vX.Y.Z`) so chart/template/policy changes do not reach
  prod when they merge to the app repo's `main`.

## Design

### Argo applications become multi-source

```yaml
spec:
  sources:
    - repoURL: https://github.com/micahg/tbltp.git
      targetRevision: main            # dev; prod uses a release tag, e.g. v0.63.0
      path: chart
      helm:
        releaseName: ntt-infra
        valueFiles:
          - values.yaml
          - $values/envs/dev/ntt.yaml
    - repoURL: https://github.com/micahg/talos-cluster.git
      targetRevision: main            # prod: main too (only approved bumps land there)
      ref: values
```

Settings stay in the app repo: with microk8s gone, `chart/values-dev.yaml` is simply the Talos dev
values (later `values-prod.yaml`). `envs/<env>/ntt.yaml` here holds **only** `releaseVersion`,
`apiImageVers` and `uiImageVers`. Same split for cobblepod (`envs/dev/cobblepod.yaml` holds its
image tags only).

### What CI changes

| Repo | Workflow | Today | After |
| --- | --- | --- | --- |
| tbltp | `deploy-dev.yaml` | PR to tbltp bumps `chart/values-talos-dev.yaml` | PR to talos-cluster bumps `envs/dev/ntt.yaml` |
| tbltp | `deploy-prod.yaml` (new) | none | after `Prod` approval: PR to talos-cluster bumps `envs/prod/ntt.yaml` pins and the chart tag (`targetRevision`) in `argocd/prod/apps/ntt.yaml` |
| cobblepod | release workflow | helm deploy with KUBECONFIG to microk8s | PR to talos-cluster bumps `envs/dev/cobblepod.yaml` |

Bump PRs: branch `deploy/<app>-<env>-<run id>`, supersede older open ones, `gh pr merge --squash`
with `gh pr update-branch` retries (same script as `deploy-dev.yaml` today).

### Credential

CI needs write access to this repo only (contents + pull requests). It never gets a kubeconfig.

- Prefer a GitHub App installed on `talos-cluster` only; a fine-grained personal access token
  (repository: talos-cluster; Contents and Pull requests: read and write) works to start.
- Secret name `TALOS_CLUSTER_TOKEN`. Dev jobs read it from the repository secrets; the prod job
  from the `Prod` environment, so it needs the approval.
- Risk: whoever can run workflows in tbltp/cobblepod can change cluster config through it.
  tbltp write access already deploys to dev through the chart, so this widens, not creates, that
  power. Keep the token's scope to this one repo and rotate it (fine-grained tokens expire).
- Branch protection here stays (PR required, linear history). The bump PRs satisfy it.

## Steps

### Phase 0: prerequisites (owner)
1. Create the token/App and add `TALOS_CLUSTER_TOKEN` to tbltp and cobblepod (prod one in the
   `Prod` environment of tbltp later).

### Phase 1: dev, tbltp
2. talos-cluster: add `envs/dev/ntt.yaml` (copy of `values-talos-dev.yaml`); convert
   `argocd/dev/apps/ntt.yaml` to multi-source reading it. Merge; Argo shows the app Synced with no
   change to the running pods. Do this in one go with step 3 so the live pins are never stale.
3. tbltp: `deploy-dev.yaml` opens the bump PR in talos-cluster (uses the token).
4. Prove it: run Deploy Dev via `workflow_dispatch` with explicit versions; check the PR merges in
   talos-cluster, Argo rolls the pods, `dev.tbltp.dev` and `dev-api.tbltp.dev` still return 200.

### Phase 2: dev, cobblepod
5. talos-cluster: `envs/dev/cobblepod.yaml` and a multi-source `cobblepod` app.
6. cobblepod: replace the helm-deploy job with the bump PR to talos-cluster; drop KUBECONFIG and
   the "development" environment secrets.

### Phase 3: cleanup
7. tbltp: delete `chart/values-talos-dev.yaml`, `chart/values-dev.yaml`, the old dev job and
   unused secrets; keep `chart/values.yaml` defaults. cobblepod: delete `values-talos-dev.yaml`.
8. After microk8s is uninstalled: remove its leftovers (DNS records, the `microk8s` kube context).

### Phase 4: prod
9. Close tbltp #551 (superseded). Rework talos-cluster #4: `argocd/prod` apps are multi-source,
   chart pinned to a release tag, values from `envs/prod/ntt.yaml`.
10. tbltp: new `deploy-prod.yaml` gated by `environment: Prod`; the DOKS helm job stays until the
    cutover (two approvals per release until then).
11. Create the prod cluster (`cluster/create.sh prod`), seal secrets, apply `root.yaml`, run beside
    DOKS on `prod.tbltp.dev` / `prod-api.tbltp.dev`, then cut over to `tbltp.dev` / `api.tbltp.dev`.

## Open items
- Open PRs affected: talos-cluster #3 (create.sh, plan) is unaffected; #4 is reworked in step 9;
  tbltp #551 is closed in step 9.
- Order matters for dev: tbltp#553 (values-dev.yaml becomes the Talos values) first; then
  talos-cluster#6 + tbltp#552 together; then delete `chart/values-talos-dev.yaml`.
- Argo CD v3.6.1 multi-source with `ref` is assumed to work as documented; step 2 is the test.
- Prod needs: Atlas prod database and user (URI must name the database), R2 bucket and
  credentials, Auth0 URLs for the test and final hostnames, a prod tunnel.
