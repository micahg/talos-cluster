#!/usr/bin/env bash
# Create a single-node Talos cluster as a KVM VM and bring Kubernetes up.
# Run ON the KVM host (mastermold), not the laptop: it needs virsh, talosctl, qemu-img, zstd,
# curl and jq, and a libvirt storage pool named "images".
#
#   ./create.sh <dev|prod>              # creates things
#   DRY_RUN=1 ./create.sh <dev|prod>    # prints what it would do
#   RESUME=1 ./create.sh <dev|prod>     # VM already exists: continue from the Talos wait
#
# It refuses to touch an existing network, domain or disk. Settings come from envs/<env>.env.
# After it finishes, follow the "Next steps" it prints (Cilium is part of the machine config, so
# the node goes Ready by itself; Argo CD and the sealed secrets key are the next steps).
set -euo pipefail
cd "$(dirname "$0")"

ENV_NAME="${1:?usage: $0 <dev|prod>}"
[ -f "envs/$ENV_NAME.env" ] || { echo "no envs/$ENV_NAME.env" >&2; exit 1; }
# shellcheck disable=SC1090
source "envs/$ENV_NAME.env"

DRY_RUN="${DRY_RUN:-}"
WORK="$HOME/talos-work"
OUT="$WORK/$ENV/_out"
TALOS_VERSION=$(cat talos-version.txt)
export PATH="$HOME/.local/bin:$PATH"
V=(virsh -c qemu:///system)

run() { if [ -n "$DRY_RUN" ]; then echo "+ $*"; else "$@"; fi; }
say() { echo; echo "== $*"; }

say "Preflight"
for c in virsh virt-install talosctl qemu-img zstd curl jq; do
  command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 1; }
done
"${V[@]}" pool-info images >/dev/null 2>&1 || { echo "libvirt pool 'images' does not exist" >&2; exit 1; }
POOL_DIR=$("${V[@]}" pool-dumpxml images | sed -n 's#.*<path>\(.*\)</path>.*#\1#p' | head -1)
DISK="$POOL_DIR/$NODE_NAME.qcow2"
SKIP_CREATE=
if "${V[@]}" dominfo "$NODE_NAME" >/dev/null 2>&1; then
  if [ -n "${RESUME:-}" ]; then
    SKIP_CREATE=1
    echo "RESUME: $NODE_NAME exists, skipping the network, image and VM steps"
  else
    echo "domain $NODE_NAME already exists (RESUME=1 continues from the Talos wait)" >&2; exit 1
  fi
elif "${V[@]}" vol-info --pool images "$NODE_NAME.qcow2" >/dev/null 2>&1; then
  echo "volume $NODE_NAME.qcow2 already exists in pool images" >&2; exit 1
fi
if [ -e "$WORK/$ENV/secrets.yaml" ] && [ -z "${REUSE_SECRETS:-}" ] && [ -z "${RESUME:-}" ]; then
  echo "$WORK/$ENV/secrets.yaml exists: a cluster was built here before." >&2
  echo "Set REUSE_SECRETS=1 to rebuild the same cluster identity from it, or move it away." >&2
  exit 1
fi
# RESUME after the config was applied: the node answers on its secured API, so do not regenerate
# the config (that would mint new Cilium keys that the node does not have).
CONFIGURED=
if [ -n "${RESUME:-}" ] && [ -z "$DRY_RUN" ] && [ -f "$OUT/talosconfig" ] \
   && talosctl version --talosconfig "$OUT/talosconfig" >/dev/null 2>&1; then
  CONFIGURED=1
  echo "RESUME: config already applied on $NODE_IP, skipping config generation"
fi
# patches/cilium.yaml holds Cilium's own private keys: render a fresh one for each cluster.
if [ -z "$CONFIGURED" ] && ! command -v helm >/dev/null; then
  [ -n "$DRY_RUN" ] && echo "warning: helm is missing (needed to render Cilium)" || { echo "missing: helm (needed to render Cilium)" >&2; exit 1; }
fi
echo "ok: pool images at $POOL_DIR, disk $DISK"

if [ -z "$SKIP_CREATE" ]; then
say "Network $NET_NAME"
if "${V[@]}" net-info "$NET_NAME" >/dev/null 2>&1; then
  echo "network $NET_NAME already exists, leaving it as is"
else
  NETXML=$(mktemp)
  cat > "$NETXML" <<XML
<network>
  <name>$NET_NAME</name>
  <forward mode='nat'/>
  <bridge name='$NET_BRIDGE' stp='on' delay='0'/>
  <ip address='$NET_GATEWAY' netmask='255.255.255.0'>
    <dhcp>
      <host mac='$NODE_MAC' name='$NODE_NAME' ip='$NODE_IP'/>
    </dhcp>
  </ip>
</network>
XML
  run "${V[@]}" net-define "$NETXML"
  run "${V[@]}" net-start "$NET_NAME"
  run "${V[@]}" net-autostart "$NET_NAME"
  rm -f "$NETXML"
fi

say "Image (Talos $TALOS_VERSION from Image Factory)"
run mkdir -p "$WORK/images" "$WORK/$ENV"
run chmod 700 "$WORK" "$WORK/$ENV"
if [ -n "$DRY_RUN" ]; then
  echo "+ POST schematic.yaml to factory.talos.dev, download metal-amd64.raw.zst, convert to a ${DISK_GB}G qcow2 and upload it as volume $NODE_NAME.qcow2 in pool images"
else
  SCHEMATIC=$(curl -sf -X POST --data-binary @schematic.yaml https://factory.talos.dev/schematics | jq -r .id)
  echo "$SCHEMATIC" > "$WORK/schematic-id.txt"
  RAW="$WORK/images/metal-amd64-$TALOS_VERSION-$SCHEMATIC.raw"
  if [ ! -f "$RAW" ]; then
    curl -sfL "https://factory.talos.dev/image/$SCHEMATIC/$TALOS_VERSION/metal-amd64.raw.zst" | zstd -d -o "$RAW"
  fi
  # The pool directory is root-owned, so build the disk next to the cached image and let libvirt
  # (which can write there) create and fill the volume. No sudo needed.
  TMPDISK="$WORK/images/$NODE_NAME.qcow2"
  qemu-img convert -O qcow2 "$RAW" "$TMPDISK"
  qemu-img resize "$TMPDISK" "${DISK_GB}G"
  "${V[@]}" vol-create-as images "$NODE_NAME.qcow2" "${DISK_GB}G" --format qcow2
  "${V[@]}" vol-upload --pool images "$NODE_NAME.qcow2" "$TMPDISK"
  rm -f "$TMPDISK"
fi

say "VM $NODE_NAME ($VCPUS vCPU, $MEM_MB MiB)"
run virt-install --connect qemu:///system --name "$NODE_NAME" \
  --memory "$MEM_MB" --vcpus "$VCPUS" --cpu host-passthrough \
  --import --disk "path=$DISK,bus=virtio" \
  --network "network=$NET_NAME,mac=$NODE_MAC,model=virtio" \
  --osinfo linux2022 --graphics none --noautoconsole
fi

if [ -z "$CONFIGURED" ]; then
say "Waiting for Talos maintenance API on $NODE_IP"
if [ -z "$DRY_RUN" ]; then
  for _ in $(seq 1 60); do
    talosctl version --insecure -n "$NODE_IP" -e "$NODE_IP" >/dev/null 2>&1 && break
    sleep 5
  done
  talosctl version --insecure -n "$NODE_IP" -e "$NODE_IP" >/dev/null 2>&1 || { echo "node did not come up" >&2; exit 1; }
fi
fi

if [ -z "$CONFIGURED" ]; then
say "Machine config"
if [ -z "$DRY_RUN" ]; then
  ./build-cilium-patch.sh
  cd "$WORK/$ENV"
  [ -f secrets.yaml ] || talosctl gen secrets -o secrets.yaml
  chmod 600 secrets.yaml
  REPO_CLUSTER="$OLDPWD"
  SCHEMATIC=$(cat "$WORK/schematic-id.txt")
  talosctl gen config "$CLUSTER_NAME" "https://$NODE_IP:6443" \
    --with-secrets secrets.yaml \
    --install-image "factory.talos.dev/installer/$SCHEMATIC:$TALOS_VERSION" \
    --kubernetes-version "$(cat "$REPO_CLUSTER/kubernetes-version.txt" | sed 's/^v//')" \
    --additional-sans "$NODE_IP" \
    --config-patch "@$REPO_CLUSTER/patches/common.yaml" \
    --config-patch "@$REPO_CLUSTER/patches/kvm.yaml" \
    --config-patch "@$REPO_CLUSTER/patches/cilium.yaml" \
    --config-patch-control-plane "@$REPO_CLUSTER/patches/controlplane.yaml" \
    --output-dir _out --force
  chmod -R go-rwx _out
  talosctl validate --config _out/controlplane.yaml --mode metal
  talosctl --talosconfig _out/talosconfig config endpoint "$NODE_IP"
  talosctl --talosconfig _out/talosconfig config node "$NODE_IP"
  # The Cilium patch embeds private keys and is gitignored: remove it from the repo checkout.
  rm -f "$REPO_CLUSTER/patches/cilium.yaml"
else
  echo "+ build-cilium-patch.sh, talosctl gen secrets/config for $CLUSTER_NAME at https://$NODE_IP:6443"
fi
fi

say "Apply, install, bootstrap"
if [ -z "$DRY_RUN" ]; then
  TC=(--talosconfig "$OUT/talosconfig")
  # RESUME-safe: the secured API only answers once a config has been applied
  if talosctl version "${TC[@]}" >/dev/null 2>&1; then
    echo "config already applied, skipping apply-config"
  else
    talosctl apply-config --insecure -n "$NODE_IP" -e "$NODE_IP" --file "$OUT/controlplane.yaml"
    for _ in $(seq 1 90); do
      talosctl version "${TC[@]}" >/dev/null 2>&1 && break
      sleep 10
    done
  fi
  # etcd waits for time sync and the CRI before it accepts a bootstrap, so retry
  for _ in $(seq 1 60); do
    if out=$(talosctl bootstrap "${TC[@]}" 2>&1); then echo "bootstrapped"; break; fi
    case "$out" in
      *"AlreadyExists"*|*"already"*) echo "already bootstrapped"; break ;;
    esac
    echo "waiting for etcd to accept bootstrap..."; sleep 10
  done
  talosctl kubeconfig "$WORK/$ENV/kubeconfig" "${TC[@]}" --force
  chmod 600 "$WORK/$ENV/kubeconfig"
else
  echo "+ talosctl apply-config, wait for reboot, bootstrap (retrying), kubeconfig"
fi

cat <<NEXT

== Next steps (cluster '$ENV')
1. Back up $WORK/$ENV/secrets.yaml to 1Password, then delete the copy on this host.
2. From the laptop, open the SSH proxy (ssh -fN -D 1080 micah@<host>) and copy the kubeconfig
   from $WORK/$ENV/kubeconfig to ~/.kube/talos-$ENV.config (add proxy-url: socks5://127.0.0.1:1080).
3. Wait for the node: KUBECONFIG=~/.kube/talos-$ENV.config kubectl get nodes
4. Install Argo CD: ./argocd/bootstrap.sh $ENV   (current kubectl context!)
5. Back up the Sealed Secrets key (kube-system secret labelled sealedsecrets.bitnami.com/sealed-secrets-key)
   to 1Password, then seal the $ENV secrets (apps/*/README.md) and push them.
NEXT
