#!/bin/bash -e
# Runs on the build VM. Clones the SDK on the host, builds it inside the vendor
# Docker image, and uploads update-<date>-<sha>.zip to DO Spaces.
# Spaces caches: buildroot dl/ (recovery package sources), the Debian base
# tarball (debootstrap result — skips the debootstrap stage of the rootfs build),
# and recovery.img (keyed on the kernel + buildroot subtree hash — skips the
# ~11 GB buildroot recovery build when the kernel tree is unchanged).
# Inputs come from environment variables set by deploy.sh over SSH.

log() { echo -e "\e[36m[build-on-vm]\e[0m $*"; }
die() { echo -e "\e[31m[build-on-vm] ERROR:\e[0m $*" >&2; exit 1; }

SDK_DIR="${SDK_DIR:-/opt/rk3576}"
GIT_REPO="${GIT_REPO:?GIT_REPO not set}"
GIT_REF="${GIT_REF:-main}"
DEFCONFIG="${DEFCONFIG:-rockchip_rk3576_armsom_sige5_defconfig}"
ROOTFS="${RK_ROOTFS_SYSTEM:-debian}"
BUILD_TARGET="${BUILD_TARGET:-}"
GH_TOKEN="${GH_TOKEN:-}"                  # optional: token for cloning a private repo
DOCKERFILE="${DOCKERFILE:-/root/Dockerfile}"
IMAGE="${IMAGE_TAG:-rk3576-build:latest}"
DEBIAN_VERSION="${RK_DEBIAN_VERSION:-bookworm}"
DEBIAN_ARCH="${RK_DEBIAN_ARCH:-arm64}"

# bucket/region come from deploy.sh (its .env or CI Variables) — no defaults here
SPACES_BUCKET="${SPACES_BUCKET:-}"
SPACES_REGION="${SPACES_REGION:-}"
SPACES_PREFIX="${SPACES_PREFIX:-}"
UPLOAD_ALL="${UPLOAD_ALL:-0}"
DO_SPACES_ACCESS_KEY="${DO_SPACES_ACCESS_KEY:-}"
DO_SPACES_SECRET_KEY="${DO_SPACES_SECRET_KEY:-}"

export DEBIAN_FRONTEND=noninteractive

# --- wait for cloud-init bootstrap (docker, git-lfs, swap) ------------------
log "waiting for host bootstrap marker (/var/lib/neko-build-ready)"
for i in $(seq 1 120); do
  [ -f /var/lib/neko-build-ready ] && break
  sleep 10
done
[ -f /var/lib/neko-build-ready ] || die "bootstrap did not finish (see /var/log/neko-bootstrap.log)"

# --- Docker image: load from the volume cache, else build and cache it ------
# Each phase runs on a fresh droplet (empty docker), so cache the image tar on
# the volume — phase 2 loads it instead of rebuilding (~10 min saved).
IMG_TAR="$(dirname "$SDK_DIR")/docker-image.tar"
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
  :
elif [ -f "$IMG_TAR" ]; then
  log "loading Docker image from volume cache"
  docker load -i "$IMG_TAR"
else
  [ -f "$DOCKERFILE" ] || die "Dockerfile not found at $DOCKERFILE"
  log "building Docker image $IMAGE"
  docker build -t "$IMAGE" - < "$DOCKERFILE"
  log "caching Docker image to volume"
  docker save -o "$IMG_TAR" "$IMAGE" || true
fi

# --- clone or update the SDK (on the host) ----------------------------------
CLONE_URL="$GIT_REPO"
if [ -n "$GH_TOKEN" ]; then
  case "$GIT_REPO" in
    https://github.com/*) CLONE_URL="https://x-access-token:${GH_TOKEN}@github.com/${GIT_REPO#https://github.com/}" ;;
  esac
fi
if [ ! -d "$SDK_DIR/.git" ]; then
  log "cloning $GIT_REPO @ $GIT_REF into $SDK_DIR"
  git clone --filter=blob:none --no-checkout "$CLONE_URL" "$SDK_DIR"
  cd "$SDK_DIR"
  git lfs install --local
  git fetch origin "$GIT_REF" --depth 1 || git fetch origin --depth 1
  git checkout "$GIT_REF"
else
  cd "$SDK_DIR"
  log "updating existing checkout to $GIT_REF"
  git fetch origin "$GIT_REF"
  git checkout -f "$GIT_REF"
  git reset --hard "origin/$GIT_REF" 2>/dev/null || git reset --hard "$GIT_REF"
fi
log "pulling LFS objects"
git lfs pull || die "git lfs pull failed"
[ -n "$GH_TOKEN" ] && git remote set-url origin "$GIT_REPO" || true

# --- Spaces caches ----------------------------------------------------------
HAVE_SPACES=0
if [ -n "$DO_SPACES_ACCESS_KEY" ] && [ -n "$DO_SPACES_SECRET_KEY" ] && [ -n "$SPACES_BUCKET" ]; then
  HAVE_SPACES=1
  umask 077
  cat > /root/.s3cfg <<EOF
[default]
access_key = ${DO_SPACES_ACCESS_KEY}
secret_key = ${DO_SPACES_SECRET_KEY}
host_base = ${SPACES_REGION}.digitaloceanspaces.com
host_bucket = %(bucket)s.${SPACES_REGION}.digitaloceanspaces.com
use_https = True
EOF
fi

# buildroot dl/: recovery (buildroot) downloads fail on dead mirrors — restore
# the package sources from Spaces instead of fetching them.
if [ "$HAVE_SPACES" = 1 ]; then
  log "restoring buildroot dl cache"
  mkdir -p "$SDK_DIR/buildroot/dl"
  s3cmd get --recursive --force s3://${SPACES_BUCKET}/cache/buildroot-dl/ "$SDK_DIR/buildroot/dl/" >/dev/null 2>&1 \
    && log "dl cache restored" || log "dl cache miss/empty"
fi

# Debian base tarball (debootstrap result): if present, mk-rootfs.sh skips the
# debootstrap stage (mk-base-debian.sh). Stable — keyed only by release+arch.
BASE_CACHE="s3://${SPACES_BUCKET}/cache/debian-base/linaro-${DEBIAN_VERSION}-${DEBIAN_ARCH}.tar.gz"
BASE_TARBALL="$SDK_DIR/debian/linaro-${DEBIAN_VERSION}-alip-cached.tar.gz"
BASE_HIT=0
if [ "$HAVE_SPACES" = 1 ] && s3cmd get --force "$BASE_CACHE" "$BASE_TARBALL" >/dev/null 2>&1; then
  BASE_HIT=1
  log "debian base cache HIT — debootstrap will be skipped"
else
  rm -f "$BASE_TARBALL"
  log "debian base cache miss — debootstrap will run"
fi

# recovery.img: buildroot recovery rootfs (~11 GB output) + recovery-kernel.
# The recovery-kernel is the *main* kernel (RK_KERNEL_RECOVERY_CFG is empty), so
# the image depends on the kernel-6.1 tree (DTS included). Key the cache on the
# kernel + buildroot subtree hashes — a hit lets us skip the long buildroot build
# and drop the prebuilt recovery.img straight into the firmware dir.
REC_HIT=0
REC_CACHE=""
REC_CACHED="$SDK_DIR/.cache-recovery.img"   # /sdk/.cache-recovery.img in container
case " $BUILD_TARGET " in
  *" recovery "*)
    KERN_TREE="$(git -C "$SDK_DIR" rev-parse HEAD:kernel-6.1 2>/dev/null || echo nokern)"
    BR_TREE="$(git -C "$SDK_DIR" rev-parse HEAD:buildroot 2>/dev/null \
      || git -C "$SDK_DIR" rev-parse HEAD:buildroot/configs 2>/dev/null || echo nobr)"
    REC_HASH="$(printf '%s' "$KERN_TREE|$BR_TREE|$DEFCONFIG" | sha1sum | cut -c1-16)"
    REC_CACHE="s3://${SPACES_BUCKET}/cache/recovery/recovery-${REC_HASH}.img"
    if [ "$HAVE_SPACES" = 1 ] && s3cmd get --force "$REC_CACHE" "$REC_CACHED" >/dev/null 2>&1; then
      REC_HIT=1
      log "recovery cache HIT ($REC_HASH) — recovery build will be skipped"
    else
      rm -f "$REC_CACHED"
      log "recovery cache miss ($REC_HASH) — recovery will be built"
    fi
    ;;
esac

# --- register arm64 binfmt (qemu with fix-binary flag) for the rootfs chroot -
log "registering arm64 binfmt"
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes >/dev/null

# --- build inside the container ---------------------------------------------
log "building (RK_ROOTFS_SYSTEM=$ROOTFS, defconfig=$DEFCONFIG, target='${BUILD_TARGET:-<full>}')"
START="$(date +%s)"
docker run --rm --privileged \
  -e RK_ROOTFS_SYSTEM="$ROOTFS" -e DEFCONFIG="$DEFCONFIG" -e BUILD_TARGET="$BUILD_TARGET" \
  -e REC_HIT="$REC_HIT" \
  -v "$SDK_DIR":/sdk -w /sdk "$IMAGE" bash -c '
    set -e
    # expose the host-registered binfmt_misc inside the container for the chroot
    mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
    git config --global --add safe.directory "*"
    ./build.sh "$DEFCONFIG"
    # build.sh handles one target at a time — loop, dont pass them all at once
    if [ -n "$BUILD_TARGET" ]; then
      for t in $BUILD_TARGET; do
        if [ "$t" = recovery ] && [ "$REC_HIT" = 1 ] && [ -f /sdk/.cache-recovery.img ]; then
          echo "[build-on-vm] using cached recovery.img"
          mkdir -p output/firmware
          cp -f /sdk/.cache-recovery.img output/firmware/recovery.img
        else
          ./build.sh "$t"
        fi
      done
    else
      ./build.sh
    fi
  '
END="$(date +%s)"
log "build finished in $(( (END - START) / 60 )) min $(( (END - START) % 60 )) s"

# cache the Debian base tarball on a miss (debootstrap just produced it)
if [ "$BASE_HIT" = 0 ] && [ "$HAVE_SPACES" = 1 ]; then
  NEW_BASE="$(ls "$SDK_DIR"/debian/linaro-${DEBIAN_VERSION}-alip-*.tar.gz 2>/dev/null | head -1)"
  if [ -f "$NEW_BASE" ]; then
    log "caching debian base tarball → $BASE_CACHE"
    s3cmd put --acl-private "$NEW_BASE" "$BASE_CACHE" >/dev/null 2>&1 \
      && log "base cached" || log "base cache upload failed"
  fi
fi

# cache recovery.img on a miss (recovery just built it)
if [ "$REC_HIT" = 0 ] && [ -n "$REC_CACHE" ] && [ "$HAVE_SPACES" = 1 ]; then
  REC_IMG="$(readlink -f "$SDK_DIR/output/firmware/recovery.img" 2>/dev/null || true)"
  if [ -f "$REC_IMG" ]; then
    log "caching recovery.img → $REC_CACHE"
    s3cmd put --acl-private "$REC_IMG" "$REC_CACHE" >/dev/null 2>&1 \
      && log "recovery cached" || log "recovery cache upload failed"
  fi
fi

# --- report artifacts -------------------------------------------------------
ART_DIR="$SDK_DIR/rockdev"
[ -d "$ART_DIR" ] || ART_DIR="$SDK_DIR/output/firmware"
log "artifacts in $ART_DIR:"
ls -lh "$ART_DIR"/ 2>/dev/null || true

# --- upload the update.img zip to DO Spaces (only once it exists) -----------
# In a split build the first phase (uboot/kernel) has no update.img yet — skip.
# The zip is named update-<build-date>-<short-sha>.zip so each artifact is
# self-identifying; the workflow finds it by listing the prefix.
UPD="$(readlink -f "$ART_DIR/update.img" 2>/dev/null || true)"
if [ "$HAVE_SPACES" = 1 ] && { [ "$UPLOAD_ALL" = "1" ] || [ -f "$UPD" ]; }; then
  SHA="$(git -C "$SDK_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  BUILD_STAMP="$(date +%Y%m%d-%H%M%S)"
  ZIP_NAME="update-${BUILD_STAMP}-${SHA}.zip"
  PREFIX="${SPACES_PREFIX:-rk3576/${GIT_REF}/${SHA}}"
  DEST="s3://${SPACES_BUCKET}/${PREFIX}"
  log "uploading to ${DEST}/ (region ${SPACES_REGION})"
  if [ "$UPLOAD_ALL" = "1" ]; then
    s3cmd put --recursive --follow-symlinks --acl-private "$ART_DIR/" "${DEST}/"
  else
    log "zipping update.img → $ZIP_NAME"
    zip -q -j "/tmp/$ZIP_NAME" "$UPD"
    s3cmd put --acl-private "/tmp/$ZIP_NAME" "${DEST}/${ZIP_NAME}"
    rm -f "/tmp/$ZIP_NAME"
  fi
  log "uploaded: ${DEST}/${ZIP_NAME}"
else
  log "no update.img yet — skipping upload"
fi
rm -f /root/.s3cfg
