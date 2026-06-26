# RK3576 SDK build environment. Package list from the vendor Docker guide
# (docs/en/Linux/Docker, §6), plus the salsa live-build/debootstrap and
# e2fsprogs versions that check-debian.sh requires for the Debian rootfs.
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
      bc binfmt-support bison bsdmainutils build-essential chrpath cmake cpio \
      curl device-tree-compiler diffstat expat expect fdisk file flex gawk git \
      git-lfs iputils-ping libegl1-mesa libelf-dev libgmp-dev libgucharmap-2-90-dev \
      liblz4-tool libmpc-dev libncurses-dev libsdl1.2-dev libssl-dev locales \
      live-build mesa-common-dev net-tools patchelf python2 python2-dev python3 \
      python-is-python3 python3-git python3-jinja2 python3-pexpect python3-pip \
      python3-pyelftools python3-subunit qemu-user-static repo rsync ssh strace \
      swig vim socat sudo texinfo time tree unzip wget s3cmd \
    && rm -rf /var/lib/apt/lists/*

# e2fsprogs v1.46.6 (mke2fs -d) — only the Debian rootfs needs it
RUN if ! mke2fs -h 2>&1 | grep -wq '\-d'; then \
      cd /usr/local/src \
      && git clone https://git.kernel.org/pub/scm/fs/ext2/e2fsprogs.git --depth 1 -b v1.46.6 \
      && cd e2fsprogs && ./configure && make -j"$(nproc)" && make install -j"$(nproc)" -k -i \
      && ldconfig; \
    fi

# debootstrap + live-build from salsa: the Debian rootfs build needs
# `lb config --debootstrap-options`, which the apt live-build lacks
RUN cd /usr/local/src \
    && git clone https://salsa.debian.org/installer-team/debootstrap.git --depth 1 -b debian/1.0.123+deb11u2 \
    && cd debootstrap && make install \
    && cd /usr/local/src \
    && apt-get remove -y live-build || true \
    && git clone https://salsa.debian.org/live-team/live-build.git --depth 1 -b "debian/1%20230131" \
    && cd live-build && rm -rf manpages/po/ && make install

RUN git lfs install --system \
    && git config --system --add safe.directory '*'

WORKDIR /sdk
