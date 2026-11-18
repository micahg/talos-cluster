# Talos Migration Plan — Agent Handoff

Last updated 2026-11-17. Dev on Talos is built and working. Prod, the cutover and cleanup remain.

**Repo split (2026-11-17):** this repo (`micahg/talos-cluster`, public) holds all cluster config for every
environment. It was `talos/` in `micahg/tbltp`, so paths in older notes below lose the `talos/` prefix.
The `ntt` Argo app still deploys `chart/` from `tbltp`; image pins stay in
`tbltp/chart/values-talos-dev.yaml` and the release workflow bumps them there. Cobblepod is planned to
run on the dev cluster from this repo. `main` here needs a PR (no direct pushes); Actions are off.

## Context

Migrating the tbltp app's hosting to Talos Linux.

- **Old dev**: microk8s on mastermold (`192.168.1.2`), served at `ntt.steakholdermeating.com` /
  `nttapi.steakholdermeating.com`. Still running. Retire at cutover.
- **Old prod**: Digital Ocean (DOKS). Cancel only after prod on Talos is stable.
- **New dev**: Talos VM on mastermold, **done and serving** `dev.tbltp.dev` (UI) and
  `dev-api.tbltp.dev` (API) through a Cloudflare Tunnel. Data migrated from the old dev Mongo.
- **Prod**: not started. Second Talos VM on the same host.
- **Constraint**: no new spend. Free tiers (GitHub, Cloudflare, Argo CD, Atlas M0, R2) plus the
  existing hardware.
- Mastermold is NOT the machine the agent runs on. `talosctl` runs on mastermold; `kubectl` runs
  from the laptop through an SSH SOCKS proxy.

## Host (mastermold, 192.168.1.2)

- 16 logical cores, ~15 GB RAM (RAM is the binding constraint), Ubuntu 26.04.1, qemu 10.2.1.
- `/` is a SATA SSD (~387 GB free). `/srv` is a RAID 5 of four spinning 8 TB disks (13 TB free).
- **VM images live on the SSD**: libvirt pool `images` = `/var/lib/libvirt/images` (autostart).
  `/srv` is for backups. An old stale copy of the dev image remains in `/srv/libvirt/images/`
  (decide: keep as a backup or delete).
- libvirt NAT network per cluster: dev `10.6.0.0/24` (node `dev-cp1` = `10.6.0.10`, DHCP
  reservation by MAC), prod `10.7.0.0/24` planned. No bridge: all external traffic is via
  Cloudflare Tunnel, so VMs need no LAN IPs.
- Dev VM: 2 vCPU, 3 GiB, single node, control plane schedulable. Idle cost ~0.5 core (measured,
  accepted; see `taloscpu.md`). Moving the disk to the SSD did not change CPU.
- Prod sizing: 1 VM, 2 to 4 vCPU, ~4 GB. A 2-node prod gives no real HA on one box. Do not run
  microk8s, dev and prod together. microk8s must be stopped to fit prod.

## Architecture (as built)

1. **Talos v1.14.5, Kubernetes v1.37.1**, pinned in `talos/cluster/talos-version.txt` and
   `kubernetes-version.txt`. Image Factory schematic with the qemu-guest-agent extension.
   Machine config uses Talos 1.14 multi-document patches (`KubeFlannelCNIConfig` deleted,
   `KubeProxyConfig` disabled, `UnattendedInstallConfig` for `/dev/vda`, control-plane taint
   removed). Patches are in `talos/cluster/patches/`.
2. **Cilium 1.20.4 is part of the machine config** (`inlineManifests`), kube-proxy replacement via
   KubePrism. It is the one chart that must be there before Argo can run. Version in
   `talos/cluster/cilium/version.txt`; upgrade manually by regenerating the patch with
   `build-cilium-patch.sh`. **The generated `patches/cilium.yaml` contains private keys and is
   gitignored. Never commit it.**
3. **GitOps with Argo CD** (chart 10.18.0), app-of-apps. `talos/argocd/bootstrap.sh <dev|prod>`
   installs Argo and applies `<env>/root.yaml`; `root` creates the apps in
   `talos/argocd/<env>/apps/` with sync waves:
   - wave -1: `sealed-secrets` (Helm 2.22.0 from bitnami.github.io/sealed-secrets, controller
     `sealed-secrets-controller` in `kube-system`)
   - wave 0: `ntt-secrets` (SealedSecrets + `ntt` namespace, `talos/apps/ntt/secrets/<env>/`)
   - wave 1: `ntt` (the Helm chart in `chart/`, values `values.yaml` + `values-talos-<env>.yaml`)
   - wave 1: `cloudflared` (`talos/apps/cloudflared/<env>/`)
   `root.yaml` is applied by hand and is not managed by Argo: changing it in Git needs a
   `kubectl apply`. Children follow Git.
4. **Secrets = Sealed Secrets**, one key per cluster. Sealed files are safe to commit but only
   decrypt on their cluster. Recipes in `talos/apps/*/README.md`. The controller key rotates
   about every 30 days: back it up again after rotation or disable rotation
   (`--key-renew-period=0`). Backups of the key and `~/talos-work/dev/secrets.yaml` are in
   1Password (copies deleted from the host).
5. **Ingress = one Cloudflare Tunnel per cluster**, `cloudflared` in-cluster (2 replicas,
   egress-only, remotely managed, token as a SealedSecret). Public hostnames (routes) are set
   in the Cloudflare dashboard, not in Git. Traffic reaches the app from the `cloudflared`
   namespace (`ingressNamespace` in values). Never route the Talos or Kubernetes APIs through
   Cloudflare or expose them.
6. **Database = MongoDB Atlas**, shared cluster `tbltp.lrmrxki.mongodb.net`. Dev uses database
   `tbltp-dev` with a user limited to it. The chart has `mongoExternal: true` for Atlas.
   **Prod's connection string may lack a database name (so it would use `test`): check.**
7. **Storage = Cloudflare R2** (S3 API). The egress rule uses `storageS3EgressPatterns:
   ["**.r2.cloudflarestorage.com"]` so the account id stays out of Git. Old and new dev share
   the `ntt-development` bucket until microk8s is retired.
8. **Auth0 tenant `nttdev`**: the application's Allowed Callback/Logout URLs include
   `https://dev.tbltp.dev/edit` (callbacks are exact-match), and an API with identifier
   `https://dev-api.tbltp.dev` exists. Prod needs the same, with prod hostnames.
9. **GitHub Actions never touches the new clusters.** No kubeconfig or SSH keys in CI.

## Promotion model (decided, not yet built)

- Dev tracks `main`: every merge deploys to dev within ~3 minutes.
- Prod tracks a **Git tag** (e.g. `prod` or `vX.Y.Z`): promote by moving the tag to a commit
  verified on dev; rollback by moving it back.
- Image versions live in `chart/values-talos-<env>.yaml`. **CI must commit version bumps there**
  instead of running `helm --set` (not built yet; bump by hand until then). The comment in
  `values-talos-dev.yaml` refers to a `talos/argocd/README.md` that does not exist yet.
- After microk8s/DOKS are gone, rename `values-talos-dev.yaml` to `values-dev.yaml` (and
  `-prod`). A `values-dev.yaml` for microk8s exists today, so delete it and the deploy-workflow
  "Dev" job first, then rename and update `valueFiles` in `ntt.yaml` and the secrets README,
  in one commit.

## Repo layout

```
talos/
├── cluster/            # versions, schematic, patches/, cilium/, build-cilium-patch.sh
├── argocd/             # values.yaml, bootstrap.sh, dev/{root.yaml,apps/}
├── apps/
│   ├── ntt/secrets/dev/        # SealedSecrets (+ namespace)
│   └── cloudflared/dev/        # namespace, deployment, policy, SealedSecret
chart/                  # the app's Helm chart (v0.10.0), values-talos-dev.yaml
taloscpu.md             # CPU investigation notes (untracked)
```

Gitignored, never committed: `secrets.yaml`, `_out/`, talosconfig, kubeconfig,
`talos/cluster/patches/cilium.yaml`. On mastermold: `~/talos-work/dev/` holds `_out/talosconfig`
and `kubeconfig` (`secrets.yaml` is in 1Password).

## Access

- Node API: on mastermold, `export PATH=$HOME/.local/bin:$PATH
  TALOSCONFIG=$HOME/talos-work/dev/_out/talosconfig; talosctl -n 10.6.0.10 -e 10.6.0.10 …`
  (flags go after the subcommand).
- VMs: `virsh -c qemu:///system …` (domain `dev-cp1`).
- kubectl from the laptop: `ssh -fN -D 1080 micah@192.168.1.2`, then
  `KUBECONFIG=~/.kube/talos-dev.config` (has `proxy-url`).

## Remaining work (rough order)

1. (Dropped by the owner: rotating the Atlas dev password. Rotate if it is ever thought leaked.)
2. Delete the `feat/talos` branch in `tbltp` (everything is on `main`; needs the owner's go-ahead).
3. Retire old dev: drop the stray `tbltp-dev` database in the old microk8s Mongo, remove "Dev"
   from the deploy matrix in `.github/workflows/deploy.yaml`, stop microk8s and
   `ntt.steakholdermeating.com`. Then do the file rename above.
4. Build the CI step that bumps image versions in `values-talos-<env>.yaml`.
5. Write `talos/cluster/create.sh <dev|prod>`: one-shot create VM (in the `images` pool),
   generate config, bootstrap, install Argo, apply `root.yaml`, restore the Sealed Secrets key.
6. Onboard cobblepod to the dev cluster (Argo app, namespace, sealed secrets, tunnel route, widen
   cloudflared egress and ingressNamespace, check VM RAM).
7. Dev telemetry (OTel/Loki egress and secrets) is deferred; exporter errors are noisy.
8. UI bug: a failed Auth0 login redirects to `/authorize` in a loop.
9. **Prod**: second VM (`10.7.0.0/24`), its own sealed secrets and Argo dir, its own tunnel and
   Auth0 settings, Atlas database check, off-box etcd snapshots and Mongo backups, run beside
   DOKS, cut over the prod hostname via its tunnel, then cancel DOKS.

## Gotchas

- Sealed secrets are encrypted to one cluster's key: a rebuilt cluster without the key backup
  means resealing every secret.
- Cloudflare tunnel public hostnames do not overwrite an existing DNS record; delete an old
  A/CNAME first.
- `mongorestore` with `--nsFrom/--nsTo` needs a URI **without** a database name, and an empty
  `$ATLAS_URI` silently connects to localhost. Guard with `${ATLAS_URI:?}`.
- Argo `CreateNamespace=true` does nothing for an app with no resources; the namespace is a
  manifest in `ntt-secrets`.
- Use bash arrays, not zsh variables, when passing `--set` args. Check `talosctl --help`; flags
  change between versions.
- Dependabot reports 4 vulnerabilities on `main` (unrelated).

## Agent behavior

- Work from the laptop for `kubectl`, and over SSH to mastermold for `talosctl` and `virsh`.
- Never store SSH keys or kubeconfigs in CI; never expose the Talos or Kubernetes API.
- Ask before creating or destroying clusters or VMs, restarting `dev-cp1`, changing host
  networking, or stopping microk8s. The user runs `sudo` commands.
- Never print or commit secrets, connection strings or tokens. Commit only after the user has
  confirmed something works.
