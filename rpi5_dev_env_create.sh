#!/usr/bin/env bash
set -euo pipefail

WORKDIR="$(pwd)/rpi5-build"
BOOT="$WORKDIR/boot"
ROOTFS="$WORKDIR/rootfs"
STAGE="$WORKDIR/stage-root"
IMG="$WORKDIR/rpi5.img"
GENIMAGE_CFG="$WORKDIR/genimage.cfg"

export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-

mkdir -p "$WORKDIR" "$BOOT" "$ROOTFS"

cd $WORKDIR

# --- Functions ---
clone_sources() {
  [ -d u-boot ]   || git clone --depth=1 https://github.com/u-boot/u-boot.git
  [ -d linux ]    || git clone --depth=1 https://github.com/raspberrypi/linux.git
  [ -d busybox ]  || git clone https://git.busybox.net/busybox
  [ -d firmware ] || git clone --depth=1 https://github.com/raspberrypi/firmware.git
}

build_uboot() {
  pushd u-boot
  make rpi_arm64_defconfig
  make -j"$(nproc)"
  popd
}

build_kernel() {
  pushd linux
  make bcm2712_defconfig
  make -j"$(nproc)" Image dtbs modules
  popd
}

build_busybox() {
  pushd busybox
  make defconfig
  make menuconfig
  make -j"$(nproc)"
  make install
  popd
}

prepare_rootfs() {
  cp -r busybox/_install/* "$ROOTFS"
  mkdir -p "$ROOTFS"/{proc,sys,dev,etc,tmp,var,usr,lib}
  make -C linux ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE \
       modules_install INSTALL_MOD_PATH="$ROOTFS"
}

prepare_boot() {
  cp firmware/boot/*.elf "$BOOT" || true
  cp firmware/boot/*.dat "$BOOT" || true
  mkdir -p "$BOOT/overlays"
  cp -r firmware/boot/overlays/* "$BOOT/overlays" || true
  cp linux/arch/arm64/boot/Image "$BOOT"
  cp linux/arch/arm64/boot/dts/broadcom/*.dtb "$BOOT"
  cp u-boot/u-boot.bin "$BOOT"

  cat > "$BOOT/config.txt" <<EOF
arm_64bit=1
enable_uart=1
kernel=u-boot.bin
EOF

  cat > "$BOOT/cmdline.txt" <<EOF
console=serial0,115200 rw
EOF
}

write_genimage_cfg() {
  cat > "$GENIMAGE_CFG" <<'EOF'
image boot.vfat {
  vfat { label = "BOOT" }
  size = 256M
  mountpoint = "/boot"
}

image rootfs.ext4 {
  ext4 { label = "rootfs" }
  size = 2048M
  mountpoint = "/"
}

image rpi5.img {
  hdimage { partition-table-type = "dos" }

  partition boot {
    partition-type = 0x0C
    bootable = "true"
    image = "boot.vfat"
  }

  partition rootfs {
    partition-type = 0x83
    image = "rootfs.ext4"
  }
}
EOF
}

generate_image() {
  rm -rf "$STAGE"
  mkdir -p "$STAGE/boot"
  cp -r "$BOOT/"* "$STAGE/boot/"
  rsync -a --exclude=boot/ "$ROOTFS/" "$STAGE/"

  if [ ! -s "$STAGE/boot/u-boot.bin" ]; then
    echo "❌ ERROR: Boot files missing"
    return 1
  fi
  if [ ! -x "$STAGE/bin/sh" ]; then
    echo "❌ ERROR: Rootfs missing"
    return 1
  fi

  rm -f "$IMG"
  genimage \
    --rootpath "$STAGE" \
    --tmppath "$WORKDIR/tmp" \
    --inputpath "$WORKDIR" \
    --outputpath "$WORKDIR" \
    --config "$GENIMAGE_CFG" \
    --loglevel 2

  echo "✅ Image ready: $IMG"
}

clean_all() {
  rm -rf "$WORKDIR" "$BOOT" "$ROOTFS" "$STAGE" "$IMG"
  echo "🧹 Cleaned build artifacts"
}

build_all() {
  clone_sources
  build_uboot
  build_kernel
  build_busybox
  prepare_rootfs
  prepare_boot
  write_genimage_cfg
  generate_image
}

# --- Menu ---
while true; do
  echo "=========================="
  echo " Raspberry Pi 5 Build Menu"
  echo "=========================="
  echo "1) Clone sources"
  echo "2) Build U-Boot"
  echo "3) Build Kernel"
  echo "4) Build BusyBox"
  echo "5) Prepare rootfs"
  echo "6) Prepare boot files"
  echo "7) Write genimage.cfg"
  echo "8) Generate SD image"
  echo "A) Build All (complete pipeline)"
  echo "9) Clean all"
  echo "0) Exit"
  read -rp "Select option: " opt

  case $opt in
    1) clone_sources ;;
    2) build_uboot ;;
    3) build_kernel ;;
    4) build_busybox ;;
    5) prepare_rootfs ;;
    6) prepare_boot ;;
    7) write_genimage_cfg ;;
    8) generate_image ;;
    A|a) build_all ;;
    9) clean_all ;;
    0) exit 0 ;;
    *) echo "Invalid option" ;;
  esac
done
