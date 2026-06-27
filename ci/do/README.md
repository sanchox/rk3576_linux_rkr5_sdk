# RK3576 image build on DigitalOcean

Builds the firmware on ephemeral DigitalOcean droplets and uploads
`update-<build-date>-<short-sha>.zip` to Spaces. A persistent Block Volume holds
the build state (SDK tree, Docker image, caches) so it survives between droplets
and builds.

## Setup

Infrastructure names (doctl context, region, Spaces bucket) are not in the
tracked code. Locally they go in `ci/do/.env` (gitignored); in CI they come from
GitHub repository **Variables** and **Secrets**.

```bash
cp ci/do/.env.example ci/do/.env        # then fill in context / region / bucket / keys
doctl auth init --context <name>        # DO API token (Droplet + Volume scopes)
ls ~/.ssh/id_ed25519_neko_do            # SSH key to reach the droplet
```

## Usage

```bash
ci/do/deploy.sh all            # full split build (creates + deletes the volume)
ci/do/deploy.sh fetch          # rsync firmware from a running droplet to ci/do/artifacts/
ci/do/deploy.sh logs           # tail the live build output on the droplet
ci/do/deploy.sh ssh            # shell into the running droplet
ci/do/deploy.sh clean          # destroy leftover droplet + volumes (aborted build)
ci/do/deploy.sh status         # show droplets + volumes
ci/do/deploy.sh volume-delete  # delete leftover build volumes
```

The volume is **ephemeral** — `all` creates `neko-rk3576-vol-<timestamp>` and
deletes it at the end (`VOLUME_KEEP=1` keeps it). The timestamped name avoids
collisions between parallel/aborted builds; `clean` removes leftovers by prefix.

### Split build (default)

`all` runs two phases, each on its **own** droplet, sharing the persistent volume:

1. **phase 1 on `SIZE` (8 vCPU)** — `misc uboot kernel recovery` (multi-threaded);
   droplet destroyed afterwards.
2. **phase 2 on `ROOTFS_SIZE` (2 vCPU)** — `rootfs updateimg` (single-threaded
   qemu); droplet destroyed afterwards.

The SDK tree, Docker image and caches live on the volume, so nothing is
transferred between phases — phase 2 picks up where phase 1 left off. The
multi-threaded part gets many cores; the qemu rootfs runs cheap on 2 vCPU.

Set `ROOTFS_SIZE=""` to disable the split (one droplet builds everything).

## Configuration (env vars)

Site-specific values (set in `.env` / CI):

| Variable | Source |
|---|---|
| `DO_CONTEXT` / `DO_ACCESS_TOKEN` | `.env` / Secret `DIGITALOCEAN_ACCESS_TOKEN` |
| `REGION` | `.env` / Variable `DO_REGION` |
| `SPACES_BUCKET` | `.env` / Variable `SPACES_BUCKET` |
| `DO_SPACES_ACCESS_KEY` / `DO_SPACES_SECRET_KEY` | `.env` / Secrets |

Defaults (override via env):

| Variable | Default |
|---|---|
| `SIZE` | `s-8vcpu-16gb` (phase 1) |
| `ROOTFS_SIZE` | `s-2vcpu-4gb` (phase 2; `""` disables split) |
| `PRE_ROOTFS_TARGET` / `ROOTFS_TARGET` | `misc uboot kernel recovery` / `rootfs updateimg` |
| `VOLUME_PREFIX` / `VOLUME_SIZE` | `neko-rk3576-vol` / `100GiB` |
| `IMAGE` | `ubuntu-22-04-x64` |
| `SSH_KEY_FILE` | `~/.ssh/id_ed25519_neko_do` |
| `GIT_REPO` / `GIT_REF` / `DEFCONFIG` | Neko-Engineering fork / `main` / sige5 |

## Files

- `deploy.sh` — orchestrator: volume + two-phase split across droplets
- `cloud-init.yaml` — droplet host setup (docker, git-lfs, s3cmd, swap)
- `Dockerfile` — SDK build environment (vendor packages + salsa live-build/debootstrap)
- `build-on-vm.sh` — runs on the droplet: mount volume, build in the container, upload
- `../../.github/workflows/build-image.yml` — CI entry point

The volume (`$MOUNT/rk3576`) persists the SDK checkout, the Docker image
(`docker-image.tar`), the buildroot `dl/` sources and the debootstrap base
tarball — so repeat builds skip clone/image-build/debootstrap. Spaces also
caches, for first-time volume population:
- `cache/buildroot-dl/` — buildroot package sources.
- `cache/debian-base/...` — debootstrap base tarball.
- `cache/recovery/recovery-<hash>.img` — prebuilt `recovery.img`, keyed on the
  `kernel-6.1` + `buildroot` subtree hashes (+ defconfig). On a hit the ~11 GB
  buildroot recovery build is skipped; the key changes whenever the kernel tree
  (DTS included) does, since the recovery-kernel is the main kernel.

`package-file` (`device/rockchip/.chips/<chip>/`) must be committed to the repo —
the build needs it to pack `update.img`, and a fresh clone won't have it otherwise.
