# Talos Migration Plan — Agent Handoff

Last updated 2026-11-21. **Dev and prod both run on Talos.** Prod has served `tbltp.dev` and
`api.tbltp.dev` since 2026-11-21. What remains is backups, a Sealed Secrets decision and cleanup
(DOKS, microk8s). See "Remaining work".

## Context

Migrated the tbltp app's hosting to Talos Linux on KVM VMs, one cluster per environment, on one host.

- **Dev**: Talos VM `dev-cp1`. `dev.tbltp.dev` (UI), `dev-api.tbltp.dev` (API) and cobblepod at
  `cobblepod.steakholdermeating.com`.
- **Prod**: Talos VM `prod-cp1`. `tbltp.dev` (UI) and `api.tbltp.dev` (API). The test hostnames
  `prod.tbltp.dev` and `prod-api.tbltp.dev` are still routed (remove them at cleanup).
- **Old dev**: microk8s on mastermold, stopped, not uninstalled.
- **Old prod**: Digital Ocean (DOKS). No longer serves traffic after the DNS cutover. Cancel it
  after prod has been stable for a week or two.
- **Constraint**: no new spend. Free tiers (GitHub, Cloudflare, Argo CD, Atlas M0, R2) plus the
  existing hardware.
- Mastermold is NOT the machine the agent runs on. `talosctl` and `virsh` run on mastermold
  (`192.168.1.2`); `kubectl` runs from the laptop through an SSH SOCKS proxy.

## Repos

- **`micahg/talos-cluster`** (this repo, public): all cluster config for every environment.
  `main` needs a PR (0 approvals, linear history, squash only, enforced for admins). Actions are off.
- **`micahg/tbltp`**: the app, its Helm chart (`chart/`) and CI. `chart/values.yaml` holds the
  **production** defaults; `chart/values-dev.yaml` overrides them for dev. No version pins there.
- **`micahg/cobblepod`**: same idea (`chart/values-dev.yaml`, pins in `envs/dev/cobblepod.yaml` here).
- Version pins live here, one file per app and environment (`envs/<env>/<app>.yaml`). App repos'
  CI opens self-merging bump PRs here with the fine-grained token `TALOS_CLUSTER_TOKEN`
  (contents and pull requests write, this repo only; set as a secret in tbltp and cobblepod).

## Host (mastermold, 192.168.1.2)

- **8 logical CPUs** (i7-3770S), ~15 GB RAM (the binding constraint), Ubuntu 26.04.1, qemu 10.2.1.
- `/` is a SATA SSD (~387 GB free). `/srv` is a RAID 5 of four spinning 8 TB disks (13 TB free),
  meant for backups.
- VM images live on the SSD: libvirt pool `images` = `/var/lib/libvirt/images` (autostart,
  root-owned). `create.sh` uploads volumes through libvirt, so it needs no sudo. An old stale copy
  of the dev image remains in `/srv/libvirt/images/` (keep as backup or delete).
- NAT network per cluster, no bridge (all external traffic goes through Cloudflare Tunnel):

| | network | node | vCPU / RAM / disk |
|---|---|---|---|
| dev | `dev` 10.6.0.0/24 | `dev-cp1` 10.6.0.10 | 2 / 3 GiB / 20 GB |
| prod | `prod` 10.7.0.0/24 | `prod-cp1` 10.7.0.10 | 2 / 4 GiB / 20 GB |

- Single node each, control plane schedulable. Idle cost ~0.5 core per VM (see `taloscpu.md`).
  Do not run microk8s alongside both clusters; it must stay stopped.

## Architecture (as built)

1. **Talos v1.14.5, Kubernetes v1.37.1**, pinned in `cluster/talos-version.txt` and
   `kubernetes-version.txt`. Image Factory schematic with the qemu-guest-agent extension.
   Machine config uses Talos 1.14 multi-document patches in `cluster/patches/`
   (`KubeFlannelCNIConfig` deleted, `KubeProxyConfig` disabled, `UnattendedInstallConfig` for
   `/dev/vda`, control-plane taint removed, `TimeSyncConfig` with `time.google.com` and
   `pool.ntp.org`, because Cloudflare NTS/UDP 123 times out from the VM NATs).
2. **Cilium 1.20.4 is part of the machine config** (`inlineManifests`), kube-proxy replacement via
   KubePrism. Version in `cluster/cilium/version.txt`; upgrade manually with
   `build-cilium-patch.sh`. **The generated `patches/cilium.yaml` contains private keys and is
   gitignored. Never commit it.**
3. **Cluster creation: `cluster/create.sh <dev|prod>`**, run on mastermold. Settings in
   `cluster/envs/<env>.env`. It builds the network, the qcow2 volume, the VM, renders Cilium
   (needs `helm` on the host), generates secrets and config, applies, bootstraps (with retry) and
   writes the kubeconfig. `DRY_RUN=1` prints the plan; `RESUME=1` continues after a failure. It
   refuses to touch existing resources.
4. **GitOps with Argo CD 3.6.1** (chart 10.18.0), app-of-apps. `argocd/bootstrap.sh <dev|prod>`
   installs Argo and applies `argocd/<env>/root.yaml`; `root` creates the apps in
   `argocd/<env>/apps/` with sync waves:
   - wave -1: `sealed-secrets` (Helm 2.22.0, controller `sealed-secrets-controller` in `kube-system`)
   - wave 0: `ntt-secrets` (SealedSecrets + the `ntt` namespace, `apps/ntt/secrets/<env>/`);
     dev also has `cobblepod-secrets`
   - wave 1: `ntt`, `cloudflared` (`apps/cloudflared/<env>/`); dev also has `cobblepod`
   `root.yaml` is applied by hand and not managed by Argo; children follow `main` here.
5. **The `ntt` app is multi-source.** Source 1 is the tbltp chart; source 2 is this repo
   (`ref: values`). Value files: `values.yaml` (prod defaults), `values-dev.yaml` (dev only) and
   `$values/envs/<env>/ntt.yaml` (pins). The **chart revision differs by environment**:
   - dev tracks tbltp `main`, so chart changes reach dev within ~2 minutes of a merge;
   - prod tracks a release tag (`v0.64.0` at the time of writing), moved by the Deploy Prod job
     in `argocd/prod/apps/ntt.yaml` after approval.
6. **Secrets = Sealed Secrets**, one key per cluster; sealed files are safe to commit and only
   decrypt on their cluster. Recipes in `apps/*/README.md` (use `read -rs`, never put values in
   shell history; with `KUBECONFIG` set to the right cluster). The controller key rotates about
   every 30 days; the current keys are backed up in 1Password but **rotation is still enabled**
   (see Remaining work).
7. **Ingress = one Cloudflare Tunnel per cluster** (`talos-dev`, `talos-prod`), `cloudflared`
   in-cluster (2 replicas, egress-only, token as a SealedSecret). Hostname routes are set in the
   Cloudflare dashboard, not in Git. Never route the Talos or Kubernetes APIs through Cloudflare.
   - dev: `dev.tbltp.dev` -> `http://ntt-ui-service.ntt.svc.cluster.local:80`,
     `dev-api.tbltp.dev` -> `http://ntt-api-service.ntt.svc.cluster.local:80`,
     `cobblepod.steakholdermeating.com` `/api*` -> `cobblepod-server.cobblepod-dev:80`, then
     everything else -> `cobblepod-ui.cobblepod-dev:80`.
   - prod: `tbltp.dev` -> ui service, `api.tbltp.dev` -> api service (same URLs as dev), plus the
     test hostnames `prod.tbltp.dev` and `prod-api.tbltp.dev` until cleanup.
8. **Database = MongoDB Atlas**, shared cluster (`*.lrmrxki.mongodb.net`). The connection string
   must name the database (prod: `tbltp`, dev: `tbltp-dev` with a user limited to it), otherwise the
   API uses `test`. The chart no longer has an in-cluster Mongo.
9. **Storage = Cloudflare R2**, prod bucket `ntt-production`, dev `ntt-development`. The egress
   rule uses `storageS3EgressPatterns: ["**.r2.cloudflarestorage.com"]` so the account id stays
   out of Git. The endpoint secret value is the bare host (the API assumes `https://`).
10. **Auth0**: dev tenant `nttdev` (`https://dev.tbltp.dev/edit`, API `https://dev-api.tbltp.dev`);
    prod tenant `tbltp` (`https://tbltp.dev/edit`, API `https://api.tbltp.dev`).
11. **GitHub Actions never touches the clusters.** No kubeconfig or SSH keys in CI.

## Build, release and deploy flow (tbltp)

- **Merge to `main`** (`build.yaml`): builds only the packages that changed since the last
  finished push build, as `ghcr.io/micahg/tbltp-{api,mui}:sha-<commit>`, then `deploy-dev.yaml`
  opens a self-merging bump PR here (`envs/dev/ntt.yaml`). Chart-only merges build nothing.
  Merges that arrive while a build runs can be skipped by the concurrency group; the last run
  covers everything since the previous finished build.
- **Pull request** (`build-check.yaml`): a PR touching a Dockerfile or `packages/mui/k8s/` builds
  the image without pushing.
- **Release** (publish a GitHub release `vX.Y.Z`, `release.yaml`): never builds. It re-tags the
  newest matching `sha-` image as the next semver and `release-X.Y.Z` (same digest), tags
  `api/vX` and `mui/vX`, then triggers `deploy.yaml`.
- **Deploy** (`deploy.yaml`): dev gets the semver pins, then `deploy-prod.yaml` waits for approval
  on the GitHub `Prod` environment (required reviewers). It then opens a self-merging PR here that
  bumps `envs/prod/ntt.yaml` and the prod chart revision (the release tag), and Argo deploys it.
  Prod only ever receives semver tags.
- Chart pod templates carry a `checksum/env-config` annotation, so a config change restarts the
  pods (the API reads its config only at startup).
- `helm.yaml` (DOKS) is unused and goes when DOKS goes.

## Repo layout

```
cluster/        versions, schematic, patches/, cilium/, envs/{dev,prod}.env, create.sh,
                build-cilium-patch.sh
argocd/         values.yaml, bootstrap.sh, {dev,prod}/{root.yaml,apps/}
apps/           ntt/secrets/{dev,prod}, cloudflared/{dev,prod}, cobblepod/secrets/dev
envs/           {dev,prod}/ntt.yaml, dev/cobblepod.yaml   (version pins only)
taloscpu.md     CPU investigation notes
```

Gitignored, never committed: `secrets.yaml`, `_out/`, talosconfig, kubeconfig,
`cluster/patches/cilium.yaml`. On mastermold: `~/talos-work/<env>/` holds `_out/talosconfig` and
`kubeconfig` (`secrets.yaml` was deleted after backing it up to 1Password) and
`~/talos-work/images/` caches the 4.4 GB disk image.

## Access

- Node API (on mastermold): `export PATH=$HOME/.local/bin:$PATH
  TALOSCONFIG=$HOME/talos-work/<env>/_out/talosconfig; talosctl -n <node-ip> -e <node-ip> …`
  Node IPs: dev 10.6.0.10, prod 10.7.0.10. `--insecure` and other flags go after the subcommand.
- VMs: `virsh -c qemu:///system …` (domains `dev-cp1`, `prod-cp1`).
- kubectl from the laptop: `ssh -fN -D 1080 micah@192.168.1.2`, then
  `KUBECONFIG=~/.kube/talos-dev.config` or `~/.kube/talos-prod.config` (both have `proxy-url`).
  The default kube context may be the old microk8s: always set `KUBECONFIG` before sealing.

## Remaining work (rough order)

1. **Backups.** No off-box etcd snapshots and no Mongo backups yet. Add a Talos etcd snapshot job
   copying to `/srv`, and check what Atlas backs up on the free tier.
2. **Sealed Secrets key rotation.** Either disable it (`--key-renew-period=0`) on both clusters or
   re-export the key after each rotation. Rebuilding a cluster without the current key means
   resealing every secret.
3. **Release re-tag test.** The re-tag step of `release.yaml` has not run yet. Do a release (even
   with no package change) and check the ghcr write permission.
4. **DOKS cleanup** after prod has been stable: cancel DOKS, delete the leftover DNS (`www`, and
   the `prod.tbltp.dev` and `prod-api.tbltp.dev` routes and records), delete `helm.yaml`, remove
   the unused GitHub environments (tbltp `Dev`; cobblepod `development` and `production`; keep tbltp
   `Prod`, it gates releases).
5. **microk8s cleanup**: `sudo snap remove microk8s`, delete the `microk8s` kube context, the old
   `ntt`/`nttapi.steakholdermeating.com` DNS records, the stray `tbltp-dev` database in microk8s's
   own in-cluster Mongo (not the Atlas dev database of the same name; take a last `mongodump`
   first), unused environment secrets.
6. Apply the `TimeSyncConfig` to the live dev node (`create.sh` already includes it for new
   clusters; dev still uses the Cloudflare default and logs UDP timeouts, though it stays synced).
7. cobblepod issue #69 (worker CPU and memory limits). Optional: an issue for
   `express-rate-limit` `ERR_ERL_UNEXPECTED_X_FORWARDED_FOR` (needs `trust proxy`).
8. Telemetry (OTel/Loki egress and secrets) is undecided for both environments; exporter errors
   are noisy.
9. UI bug: a failed Auth0 login redirects to `/authorize` in a loop.
10. Delete the `feat/talos` branch in tbltp (needs the owner's go-ahead).
11. Security follow-up: revoke Auth0 sessions (a HAR file with token responses was briefly pushed
    to a public PR branch in tbltp), and optionally ask GitHub support to purge the old commits
    (`348c06b`, `587f27e`).

## Gotchas

- Sealed secrets are encrypted to one cluster's key and to a name and namespace.
- Cloudflare tunnel hostname routes do not overwrite an existing DNS record; delete the old
  A/CNAME first. If a route's record is missing, add a proxied CNAME to
  `<tunnel-uuid>.cfargotunnel.com`.
- DNS negative caching: a hostname looked up before its record existed stays "not found" for up to
  the zone's SOA minimum (30 minutes) in `systemd-resolved` and the router (OpenWrt dnsmasq:
  `killall -HUP dnsmasq`). Browsers with DoH may work while curl does not.
- Cilium: `toFQDNs` only works if DNS goes through the proxy (`toEndpoints` kube-dns with
  `rules.dns`); `*.x` matches one label, `**.x` many. Cobblepod's worker has 80/443 egress to the
  internet except private ranges.
- Argo CD `CreateNamespace=true` does nothing for an app with no resources; the namespace is a
  manifest in `ntt-secrets`. Argo reports a ComparisonError (and keeps running state) if a
  values file listed in an Application is missing.
- `mongorestore` with `--nsFrom/--nsTo` needs a URI without a database name, and an empty
  `$ATLAS_URI` silently connects to localhost. Guard with `${ATLAS_URI:?}`.
- zsh does not word-split unquoted variables: use arrays or `$=VAR`. Use `printf …; read -rs VAR`
  (not `read -p`) in zsh.
- `gh pr edit` fails (GraphQL deprecation): use `gh api -X PATCH`.
- GitHub keeps one pending run per concurrency group and cancels the older pending one; a running
  one is never cancelled (`cancel-in-progress: false`).
- In `~/dev/tbltp`, never `git add -A`: the working tree holds untracked scratch files. Stage
  files by name and check the PR's file list.
- Dependabot reports vulnerabilities on `main` (unrelated to this work) and its base-image bumps
  now arrive as PRs.

## Agent behavior

- Work from the laptop for `kubectl`, and over SSH to mastermold for `talosctl` and `virsh`.
- Never store SSH keys or kubeconfigs in CI; never expose the Talos or Kubernetes API.
- Ask before creating or destroying clusters or VMs, restarting a node, changing host networking,
  or stopping or removing microk8s. The user runs `sudo` commands.
- Never print or commit secrets, connection strings or tokens; the user seals them. Commit only
  after the user has confirmed something works.
