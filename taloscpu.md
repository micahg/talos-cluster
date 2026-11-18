# Talos dev VM CPU investigation (handoff)

Goal: find out why the Talos dev VM uses so much host CPU while idle, lower it, and decide
whether its disk should move off the RAID array onto the SSD. Nothing here has been changed
yet. All numbers below were measured on 2026-11-12 to 2026-11-15.

## Setup

- Host: `mastermold`, `192.168.1.2`, Ubuntu 26.04.1, kernel 7.3, qemu 10.2.1, libvirt. 16 logical
  cores, ~15 GB RAM (about 9 GB available). Reach it with `ssh micah@192.168.1.2`.
- Guest: Talos Linux v1.14.5, Kubernetes v1.37.1, **single node** (control plane that also runs
  workloads). libvirt domain `dev-cp1`, 2 vCPU, 3 GiB RAM, IP `10.6.0.10` (DHCP reservation on the
  libvirt NAT network `dev`, 10.6.0.0/24). CPU mode `host-passthrough`.
- Disk: virtio, driver `name=qemu type=qcow2` with no cache/io/discard options set, 5.7 GB used.
  **Location changed on 2026-11-15 by another session:** all measurements below were taken with
  the image on `/srv/libvirt/images/dev-cp1.qcow2` (the RAID 5 array). `virsh domblklist` now
  reports `/var/lib/libvirt/images/dev-cp1.qcow2` (on the SSD, `/dev/sda2`). The qemu process was
  not restarted (same pid 674433, started 2026-11-11 18:59), so the move was done live, probably
  with `virsh blockcopy --pivot`. Not yet confirmed. The old file is still in `/srv/libvirt/images/`
  (stale, last written 16:34). The libvirt storage pool `images` has since been redefined to
  `/var/lib/libvirt/images` (autostart on), so new `virsh`/`virt-install` volumes land on the SSD.
  Decide whether to keep the old `/srv` copy as a backup or delete it.
- Storage on the host:
  - `/` is `/dev/sda2`, a WDC WDS500G2B0A SATA SSD, 457 GB, 387 GB free.
  - `/srv` is `/dev/md0`, **RAID 5 over four spinning 8 TB disks** (sdb to sde, 512k chunk, ~22 TB,
    13 TB free, 44% used). I/O scheduler is `mq-deadline`. Mostly used as bulk storage.
- Workloads in the guest: Cilium 1.20.4 (kube-proxy replacement, installed through the machine
  config as `inlineManifests`), CoreDNS, Argo CD (chart 10.18.0, about 5 pods, app-of-apps),
  Sealed Secrets, cloudflared (2 replicas), and the app (UI, API, no in-cluster Mongo; it uses
  Atlas). The app is near idle.
- Repo: `talos/cluster/patches/*.yaml` (machine config), `talos/cluster/cilium/values.yaml`,
  `talos/argocd/`, `talos/apps/`. Talos secrets and the config live on mastermold in
  `~/talos-work/dev/` (`_out/talosconfig`, `kubeconfig`, `secrets.yaml`).

## How to look (all read-only)

    ssh micah@192.168.1.2
    export PATH=$HOME/.local/bin:$PATH
    export TALOSCONFIG=$HOME/talos-work/dev/_out/talosconfig
    N=10.6.0.10
    talosctl -n $N -e $N processes           # CPU-TIME column is cumulative seconds
    talosctl -n $N -e $N read /proc/pressure/cpu
    virsh -c qemu:///system dumpxml dev-cp1
    top -H -b -n 2 -d 10 -p $(pgrep -f 'qemu-system-x86_64.*dev-cp1') -o %CPU

`kubectl top` does not work (no metrics-server). From the laptop, kubectl goes through an SSH
SOCKS proxy (`ssh -fN -D 1080 micah@192.168.1.2`, kubeconfig `~/.kube/talos-dev.config`).

## What was measured

Host, qemu process (pid 674433, about 2.9 GB resident):

- `top` shows the qemu process at roughly 65 to 70% of one core, steadily. It had used 277
  CPU-minutes when first checked.
- Per thread (10 s sample): `CPU 0/KVM` about 32% and `CPU 1/KVM` about 32%. The main qemu
  thread, the `IO` thread (disk) and `vhost` (network) are each at 0.1 to 0.2%. So the cost is
  guest execution plus KVM exits on the two vCPUs, **not** disk or network emulation in qemu.
- Host `vmstat`: ~8 to 10k interrupts/s and ~11 to 13k context switches/s (whole host, so
  this includes the VM). Host CPU is about 86% idle, load about 1.5.
- Host I/O pressure (`/proc/pressure/io`): some 3 to 5%, full 3 to 4% (whole host).

Guest (30 s sample of per-process CPU, as a share of one core; total about 25%):

| Process | CPU |
| --- | --- |
| kube-apiserver | 5.7% |
| kubelet | 4.7% |
| cilium-agent | 3.9% |
| etcd | 2.7% |
| containerd | 2.1% |
| kube-controller-manager | 1.9% |
| Talos init | 1.9% |
| Talos console dashboard | 1.2% |
| cilium-operator, scheduler | about 0.6% each |

- Guest load average is about 1.4 to 1.5 on 2 vCPUs. `/proc/pressure/cpu`: some avg10 about 11%.
- **Unexplained gap:** the guest's processes account for about 25% of one core, but the host
  sees about 65% on the vCPU threads. The rest could be guest kernel time (softirq, eBPF,
  timer ticks, IRQs), idle-loop or halt-polling cost, or VM exit overhead. This is not yet
  measured. Process CPU-time does not include interrupt and softirq time.

## Hypotheses to test, roughly in order

1. **Guest kernel/interrupt overhead.** Read `/proc/stat` (user, system, irq, softirq, iowait,
   steal) twice a few seconds apart in the guest, and `/proc/interrupts` and `/proc/softirqs`.
   Is something ticking or polling constantly? Check for a high timer-interrupt rate.
2. **KVM exit cost.** On the host, `perf kvm stat` (or `perf stat -e 'kvm:*'`) on the qemu pid to
   see exit reasons and rates (HLT, MSR writes, EPT violations, I/O). A VM with a high HLT/timer
   exit rate burns CPU while "idle".
3. **VM hardware that costs CPU for no benefit.** Check the domain XML for a graphical console
   (the Talos dashboard draws on it, 1.2% in the guest), `memballoon`, USB/tablet, a video
   device, and the clock/timer setup (`rtc tickpolicy=catchup`, `pit tickpolicy=delay`,
   no `kvmclock`/`hypervclock` tuning). Compare against a recommended minimal headless setup.
4. **Cilium.** `cilium-agent` is the third biggest process. Look at Hubble (is it enabled?),
   BPF monitor aggregation, health checks, `bpf.*` map sizing, and whether kube-proxy replacement
   and the policy loads are doing periodic work. See `talos/cluster/cilium/values.yaml`. Changing
   it means regenerating `talos/cluster/patches/cilium.yaml` (gitignored, contains private keys)
   with `build-cilium-patch.sh` and applying the machine config.
5. **Control-plane chatter.** kube-apiserver and etcd at the top suggests heavy watch/list
   traffic. Check the Argo CD application-controller (refresh and reconcile intervals, resync
   period, number of watched resources), cloudflared and Sealed Secrets, and kube-apiserver
   metrics for the top request sources. Look at etcd fsync latency
   (`etcd_disk_wal_fsync_duration_seconds`) as well.
6. **Right-sizing.** Is 2 vCPU the right number for this idle load, and would 1 vCPU lower the
   idle overhead (one fewer vCPU thread to idle-poll)? Note that Talos and this workload may not
   run well on 1.

## Result of moving the disk to the SSD (2026-11-15, same session day)

After the move to `/var/lib/libvirt/images` the CPU is essentially unchanged:

| | Before (on RAID, `/srv`) | After (on SSD) |
| --- | --- | --- |
| `CPU 0/KVM` thread | about 32% | about 38% |
| `CPU 1/KVM` thread | about 32% | about 35% |
| Guest `/proc/pressure/cpu` some avg300 | about 12.0% | about 10.9% |

So **disk placement is not the main cause of the CPU use.** The disk may still help etcd latency,
but it did not lower the idle CPU. This leaves the guest-kernel, KVM-exit and VM-hardware
hypotheses (1 to 3 above) as the lead suspects. Caveat: the "after" numbers are one 10 s sample
and the move was done outside this investigation, so the copy method and any other changes made
at the same time are unknown. Ask the user what exactly was run.

## Question: move the disk off the RAID? (earlier analysis; see the result above)

Originally `dev-cp1.qcow2` was on the RAID 5 array of spinning disks. etcd calls `fsync` on every
write, and RAID 5 on spinning disks has a high write penalty (read-modify-write), so each fsync
can take milliseconds. That can make etcd and the apiserver slower and stall the guest in
iowait. The SSD at `/` (WDC WDS500G2B0A SATA, 387 GB free, 11% used) has much lower latency.

What the data shows so far: the I/O thread is idle (0.1%), host `some` I/O pressure is 3 to 5%,
and one array member (sdc) showed 42% utilisation at under 1 write/s, which suggests slow
individual writes rather than heavy throughput. This hasn't yet been tied to etcd's fsync
latency, so measure before deciding:

- Guest etcd fsync latency (`etcd_disk_wal_fsync_duration_seconds`) and backend commit duration.
- Host `iostat -x 1` on `md0` and the member disks (w_await), while the VM is idle.
- Try the same VM image on the SSD (`/var/lib/libvirt/images` or a new pool on `/`) and compare
  etcd fsync latency and the vCPU thread CPU.

Things to weigh:

- Putting the image on `/` gives up RAID redundancy for the VM, so back up etcd (`talosctl
  etcd snapshot`) and anything stateful to `/srv`. The app's data is in Atlas and R2, so loss
  of the VM disk is a rebuild, not data loss. The Sealed Secrets key and
  `~/talos-work/dev/secrets.yaml` are **not** backed up anywhere yet. Fix that first.
- SSD wear: etcd writes steadily but lightly. Check SMART (`smartctl -a /dev/sda`) for wear.
- Cheaper options on the existing array: `cache='none' io='native'` (or `threads`) on the disk
  driver, a raw image instead of qcow2, preallocated qcow2 (`preallocation=metadata`), and
  `discard='unmap'`.
- Prod will later be a second VM on this same host (planned 10.7.0.0/24). Whatever is decided
  here applies to it too, and the two VMs would compete for the same disk.

## Constraints for whoever works on this

- Ask before changing the VM definition, restarting `dev-cp1`, rebuilding the cluster, or
  changing host networking. A restart briefly takes `dev.tbltp.dev` down.
- The user runs anything needing `sudo` themselves. Provide the command and wait.
- Never commit or print `secrets.yaml`, `_out/`, talosconfig, kubeconfig, or
  `talos/cluster/patches/cilium.yaml`. Don't expose the Talos or Kubernetes API, and don't
  route them through Cloudflare.
- Machine-config changes go in `talos/cluster/patches/` and need `talosctl apply-config`
  (some need a reboot). Check `talosctl apply-config --help` and the Talos 1.14 docs for flags;
  they change between versions.
- Prefer one change at a time and re-measure with the same commands above, so results are
  comparable. Record before and after numbers.

## Deliverable

A short report: where the CPU actually goes (with measurements), which changes lowered it and by
how much, and a recommendation on moving the disk (with fsync latency before and after).
