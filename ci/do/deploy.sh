#!/bin/bash -e
#
# Build the RK3576 firmware on ephemeral DigitalOcean droplets, with a persistent
# Block Volume holding the build state (SDK tree, Docker image, caches).
#
# Default build = split across two droplets, sharing the volume:
#   phase 1 (8 vCPU): misc + uboot + kernel + recovery   (multi-threaded)
#   phase 2 (2 vCPU): rootfs + updateimg                  (single-threaded qemu)
# State stays on the volume between phases — nothing is transferred.
#
# Commands: all | fetch | clean | ssh | logs | volume-delete | status
# Setup and configuration: see ci/do/README.md

export LD_PRELOAD=""

HERE="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
# Local config (gitignored): infra names — doctl context, region, Spaces bucket —
# live here or in the environment, not in the tracked code. See .env.example.
[ -f "$HERE/.env" ] && . "$HERE/.env"

# --- config (override via env or .env) --------------------------------------
DO_CONTEXT="${DO_CONTEXT:-}"
DO_ACCESS_TOKEN="${DO_ACCESS_TOKEN:-${DIGITALOCEAN_ACCESS_TOKEN:-}}"
REGION="${REGION:-}"
SIZE="${SIZE:-s-8vcpu-16gb}"             # phase 1 (multi-threaded)
ROOTFS_SIZE="${ROOTFS_SIZE:-s-2vcpu-4gb}" # phase 2 (qemu rootfs); ="" disables the split
PRE_ROOTFS_TARGET="${PRE_ROOTFS_TARGET:-misc uboot kernel recovery}"
ROOTFS_TARGET="${ROOTFS_TARGET:-rootfs updateimg}"
IMAGE="${IMAGE:-ubuntu-22-04-x64}"
NAME_PREFIX="${NAME_PREFIX:-neko-rk3576-build}"
SSH_KEY_FILE="${SSH_KEY_FILE:-$HOME/.ssh/id_ed25519_neko_do}"

# Ephemeral volume — unique name per build (like the droplet), so leftovers from
# an aborted build and parallel builds don't collide. Found by prefix for clean.
VOLUME_PREFIX="${VOLUME_PREFIX:-neko-rk3576-vol}"
VOLUME_NAME="${VOLUME_NAME:-$VOLUME_PREFIX-$(date +%Y%m%d-%H%M%S)}"
VOLUME_SIZE="${VOLUME_SIZE:-100GiB}"
MOUNT="/mnt/build"                        # volume mount point on the droplet
SDK_ON_VOLUME="$MOUNT/rk3576"

GIT_REPO="${GIT_REPO:-https://github.com/Neko-Engineering/rk3576_linux_rkr5_sdk.git}"
GIT_REF="${GIT_REF:-main}"
DEFCONFIG="${DEFCONFIG:-rockchip_rk3576_armsom_sige5_defconfig}"
RK_ROOTFS_SYSTEM="${RK_ROOTFS_SYSTEM:-debian}"
BUILD_TARGET="${BUILD_TARGET:-}"
GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

SPACES_BUCKET="${SPACES_BUCKET:-}"
SPACES_REGION="${SPACES_REGION:-$REGION}"
SPACES_PREFIX="${SPACES_PREFIX:-}"
UPLOAD_ALL="${UPLOAD_ALL:-0}"
DO_SPACES_ACCESS_KEY="${DO_SPACES_ACCESS_KEY:-}"
DO_SPACES_SECRET_KEY="${DO_SPACES_SECRET_KEY:-}"

ARTIFACT_DIR="${ARTIFACT_DIR:-$HERE/artifacts}"
CLOUD_INIT="$HERE/cloud-init.yaml"
BUILD_SCRIPT="$HERE/build-on-vm.sh"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$HOME/.ssh/known_hosts_neko_do -o ConnectTimeout=15"

# --- helpers ----------------------------------------------------------------
log()  { echo -e "\e[36m[deploy]\e[0m $*" >&2; }
warn() { echo -e "\e[33m[deploy]\e[0m $*" >&2; }
die()  { echo -e "\e[31m[deploy] ERROR:\e[0m $*" >&2; exit 1; }

doctl_neko() {
  if [ -n "$DO_ACCESS_TOKEN" ]; then doctl "$@" --access-token "$DO_ACCESS_TOKEN"
  else doctl "$@" --context "$DO_CONTEXT"; fi
}

show_account() {
  local info
  info="$(doctl_neko account get --format Email,Team --no-header 2>/dev/null)" \
    && log "DigitalOcean account: $info" || true
}

remote() { ssh $SSH_OPTS -i "$SSH_KEY_FILE" "root@$1" "${@:2}"; }
droplet_id() {
  doctl_neko compute droplet list --format ID,Name --no-header 2>/dev/null \
    | awk -v p="^${NAME_PREFIX}-" '$2 ~ p {print $1}' | head -n1
}
droplet_ip() { doctl_neko compute droplet get "$1" --format PublicIPv4 --no-header 2>/dev/null; }

ssh_key_fingerprint() {
  local pub="$SSH_KEY_FILE.pub"
  [ -f "$pub" ] || die "SSH public key not found: $pub"
  ssh-keygen -lf "$pub" -E md5 | awk '{print $2}' | sed 's/^MD5://'
}

wait_for_ssh() {
  local ip="$1"
  log "waiting for SSH on $ip"
  for i in $(seq 1 60); do
    ssh $SSH_OPTS -i "$SSH_KEY_FILE" "root@$ip" true 2>/dev/null && { log "SSH up"; return 0; }
    sleep 5
  done
  die "SSH never came up on $ip"
}

# --- volume -----------------------------------------------------------------
volume_id() {  # exact name (this build's volume)
  doctl_neko compute volume list --format ID,Name --no-header 2>/dev/null \
    | awk -v n="$VOLUME_NAME" '$2==n {print $1}' | head -n1
}

# IDs of all our volumes by prefix (for cleaning up leftovers).
volumes_by_prefix() {
  doctl_neko compute volume list --format ID,Name --no-header 2>/dev/null \
    | awk -v p="^${VOLUME_PREFIX}-" '$2 ~ p {print $1}'
}

ensure_volume() {
  log "creating volume $VOLUME_NAME ($VOLUME_SIZE, ext4) in $REGION"
  doctl_neko compute volume create "$VOLUME_NAME" --region "$REGION" \
    --size "$VOLUME_SIZE" --fs-type ext4 --format ID --no-header
}

attach_and_mount() {
  local did="$1" ip="$2" vid="$3"
  log "attaching volume $VOLUME_NAME to droplet $did"
  doctl_neko compute volume-action attach "$vid" "$did" --wait >/dev/null
  remote "$ip" "
    mkdir -p '$MOUNT'
    dev=/dev/disk/by-id/scsi-0DO_Volume_${VOLUME_NAME}
    for i in \$(seq 1 15); do [ -e \"\$dev\" ] && break; sleep 2; done
    mountpoint -q '$MOUNT' || mount \"\$dev\" '$MOUNT'
    mkdir -p '$SDK_ON_VOLUME'
  "
}

# --- build ------------------------------------------------------------------
run_build_on_vm() {
  local ip="$1" target="$2"
  scp $SSH_OPTS -i "$SSH_KEY_FILE" "$HERE/Dockerfile" "root@$ip:/root/Dockerfile"
  log "build-on-vm on root@$ip (target='${target:-<full>}')"
  ssh $SSH_OPTS -i "$SSH_KEY_FILE" "root@$ip" \
    "SDK_DIR='$SDK_ON_VOLUME' \
     GIT_REPO='$GIT_REPO' GIT_REF='$GIT_REF' DEFCONFIG='$DEFCONFIG' \
     RK_ROOTFS_SYSTEM='$RK_ROOTFS_SYSTEM' BUILD_TARGET='$target' GH_TOKEN='$GH_TOKEN' \
     SPACES_BUCKET='$SPACES_BUCKET' SPACES_REGION='$SPACES_REGION' \
     SPACES_PREFIX='$SPACES_PREFIX' UPLOAD_ALL='$UPLOAD_ALL' \
     DO_SPACES_ACCESS_KEY='$DO_SPACES_ACCESS_KEY' DO_SPACES_SECRET_KEY='$DO_SPACES_SECRET_KEY' \
     bash -s" < "$BUILD_SCRIPT"
}

# Run one phase on its own droplet: create → attach volume → build → destroy.
run_phase() {
  local size="$1" target="$2" vid="$3" name id ip fp
  fp="$(ssh_key_fingerprint)"
  name="$NAME_PREFIX-$(date +%Y%m%d-%H%M%S)"
  log "phase on $size: creating droplet $name"
  doctl_neko compute droplet create "$name" \
    --region "$REGION" --size "$size" --image "$IMAGE" \
    --ssh-keys "$fp" --enable-monitoring \
    --user-data "$(cat "$CLOUD_INIT")" --wait --format ID,Name,PublicIPv4
  id="$(droplet_id)"; ip="$(droplet_ip "$id")"
  wait_for_ssh "$ip"
  attach_and_mount "$id" "$ip" "$vid"
  run_build_on_vm "$ip" "$target"
  log "phase done — destroying droplet $id (volume kept)"
  doctl_neko compute volume-action detach "$vid" "$id" --wait >/dev/null 2>&1 || true
  doctl_neko compute droplet delete "$id" --force
}

cmd_all() {
  [ -n "$REGION" ] || die "REGION not set (put it in ci/do/.env or pass REGION=...; see .env.example)"
  [ -n "$DO_ACCESS_TOKEN" ] || [ -n "$DO_CONTEXT" ] \
    || die "no DigitalOcean auth — set DO_ACCESS_TOKEN or DO_CONTEXT (see ci/do/.env.example)"
  show_account
  [ -f "$CLOUD_INIT" ] && [ -f "$BUILD_SCRIPT" ] && [ -f "$HERE/Dockerfile" ] \
    || die "missing cloud-init.yaml / build-on-vm.sh / Dockerfile in $HERE"
  [ -n "$(droplet_id)" ] && die "a '$NAME_PREFIX-*' droplet already exists; run 'clean' first"
  { [ -n "$DO_SPACES_ACCESS_KEY" ] && [ -n "$DO_SPACES_SECRET_KEY" ] && [ -n "$SPACES_BUCKET" ]; } \
    || warn "DO_SPACES_*/SPACES_BUCKET not set — update.img will not be uploaded"
  local vid; vid="$(ensure_volume)"
  if [ -n "$ROOTFS_SIZE" ] && [ "$ROOTFS_SIZE" != "$SIZE" ]; then
    log "split build via volume $VOLUME_NAME: phase1=$SIZE, phase2=$ROOTFS_SIZE"
    run_phase "$SIZE"        "$PRE_ROOTFS_TARGET" "$vid"
    run_phase "$ROOTFS_SIZE" "$ROOTFS_TARGET"     "$vid"
  else
    run_phase "$SIZE" "$BUILD_TARGET" "$vid"
  fi
  # Ephemeral volume: delete after the build (set VOLUME_KEEP=1 to keep it for
  # faster repeat builds — SDK checkout / docker image / caches stay on it).
  if [ "${VOLUME_KEEP:-0}" = 1 ]; then
    log "done — update-<date>-<sha>.zip in s3://$SPACES_BUCKET/ (volume $VOLUME_NAME kept)"
  else
    log "deleting volume $VOLUME_NAME"
    doctl_neko compute volume delete "$vid" --force
    log "done — update-<date>-<sha>.zip in s3://$SPACES_BUCKET/"
  fi
}

cmd_fetch() {
  show_account
  local id ip; id="$(droplet_id)"; [ -n "$id" ] || die "no build droplet running"
  ip="$(droplet_ip "$id")"
  mkdir -p "$ARTIFACT_DIR"
  rsync -avh --progress -e "ssh $SSH_OPTS -i $SSH_KEY_FILE" \
    "root@$ip:$SDK_ON_VOLUME/rockdev/" "$ARTIFACT_DIR/" \
    || rsync -avh --progress -e "ssh $SSH_OPTS -i $SSH_KEY_FILE" \
       "root@$ip:$SDK_ON_VOLUME/output/firmware/" "$ARTIFACT_DIR/"
  log "done: $ARTIFACT_DIR"
}

# Destroy leftover build droplet + volumes (from an aborted build).
cmd_clean() {
  show_account
  local id; id="$(droplet_id)"
  if [ -n "$id" ]; then doctl_neko compute droplet delete "$id" --force && log "deleted droplet $id"
  else log "no '$NAME_PREFIX-*' droplet"; fi
  # droplet delete auto-detaches; remove any leftover prefixed volumes
  for v in $(volumes_by_prefix); do
    doctl_neko compute volume delete "$v" --force >/dev/null 2>&1 && log "deleted volume $v" || true
  done
}

cmd_volume_delete() {
  show_account
  local any=0
  for v in $(volumes_by_prefix); do
    doctl_neko compute volume delete "$v" --force >/dev/null 2>&1 && { log "deleted volume $v"; any=1; }
  done
  [ "$any" = 1 ] || log "no $VOLUME_PREFIX-* volumes"
}

cmd_status() {
  show_account
  echo "--- droplets ---"
  doctl_neko compute droplet list --format ID,Name,PublicIPv4,Status,Memory,VCPUs 2>/dev/null \
    | awk -v p="^${NAME_PREFIX}-" 'NR==1 || $2 ~ p'
  echo "--- volumes ---"
  doctl_neko compute volume list --format Name,Size,Region,DropletIDs 2>/dev/null \
    | awk -v p="^${VOLUME_PREFIX}-" 'NR==1 || $1 ~ p'
}

# Open a shell on the running build droplet (SDK is at /mnt/build/rk3576).
cmd_ssh() {
  local id ip; id="$(droplet_id)"; [ -n "$id" ] || die "no build droplet running"
  ip="$(droplet_ip "$id")"
  exec ssh $SSH_OPTS -i "$SSH_KEY_FILE" "root@$ip"
}

# Tail the live build output on the droplet (the build runs inside Docker).
cmd_logs() {
  local id ip; id="$(droplet_id)"; [ -n "$id" ] || die "no build droplet running"
  ip="$(droplet_ip "$id")"
  remote "$ip" 'cid=$(docker ps -q | head -1)
    if [ -n "$cid" ]; then docker logs -f "$cid"
    else tail -n +1 -F "$(ls -t /mnt/build/rk3576/output/sessions/*/build_*.log 2>/dev/null | head -1)"; fi'
}

# ----------------------------------------------------------------------------
case "${1:-all}" in
  all)           cmd_all ;;
  fetch)         cmd_fetch ;;
  clean)         cmd_clean ;;
  ssh)           cmd_ssh ;;
  logs)          cmd_logs ;;
  volume-delete) cmd_volume_delete ;;
  status)        cmd_status ;;
  *) die "unknown command '$1' (use: all|fetch|clean|ssh|logs|volume-delete|status)" ;;
esac
