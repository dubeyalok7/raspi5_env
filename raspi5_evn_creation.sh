#!/usr/bin/env bash
#
# bootstrap_rpi5_builder.sh — Create a Dockerized RPi5 image build project
# Author: AI Powered
# Version: 1.0.0
#
set -euo pipefail

# Configuration
PROJECT_DIR="rpi5_builder_project"
WRAPPER="docker_build.sh"
DOCKERFILE="Dockerfile"
BUILD_SCRIPT="build_rpi5_image.sh"
README="README.md"

# Color codes
C_RESET='\033[0m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_RED='\033[0;31m'

log()    { echo -e "${C_GREEN}[INFO]${C_RESET} $*"; }
warn()   { echo -e "${C_YELLOW}[WARN]${C_RESET} $*"; }
die()    { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; exit 1; }

# Pre-flight checks
command -v docker >/dev/null 2>&1 || die "Docker is not installed or not in PATH."
mkdir -p "${PROJECT_DIR}"
cd "${PROJECT_DIR}"

# ---------------------------------------------------
# 1. Write docker_build.sh
# ---------------------------------------------------
cat > "${WRAPPER}" << 'EOF'
#!/usr/bin/env bash
#
# docker_build.sh — Build & run the Docker image for RPi5 build
set -euo pipefail

IMAGE_NAME="rpi5-builder"
TAG="latest"

echo "[INFO] Building Docker image ${IMAGE_NAME}:${TAG}..."
docker build --no-cache -t "${IMAGE_NAME}:${TAG}" .

echo "[INFO] Launching container..."
docker run --rm -it \
  --privileged \
  -v "$PWD":/build \
  "${IMAGE_NAME}:${TAG}"
EOF
chmod +x "${WRAPPER}"

# ---------------------------------------------------
# 2. Write Dockerfile
# ---------------------------------------------------
cat > "${DOCKERFILE}" << 'EOF'
# Dockerfile — Ubuntu-based build environment for RPi5 custom images
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    git wget xz-utils curl rsync \
    kpartx qemu-user-static binfmt-support dosfstools e2fsprogs libguestfs-tools proot \
    crossbuild-essential-arm64 \
    build-essential \
    bc bison flex libssl-dev libncurses-dev \
    device-tree-compiler \
    python3 python3-pip python3-cryptography openssl \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /build

COPY build_rpi5_image.sh /usr/local/bin/build_rpi5_image.sh
RUN chmod +x /usr/local/bin/build_rpi5_image.sh

CMD ["/usr/local/bin/build_rpi5_image.sh"]
EOF

# ---------------------------------------------------
# 3. Write build_rpi5_image.sh
# ---------------------------------------------------
cat > "${BUILD_SCRIPT}" << 'EOF'
#!/usr/bin/env bash
#
# build_rpi5_image.sh — Menu-driven RPi5 image builder inside Docker
set -euo pipefail

# Colors
C_RESET='\033[0m'; C_INFO='\033[0;34m'; C_OK='\033[0;32m'; C_WARN='\033[0;33m'; C_ERR='\033[0;31m'

log()    { echo -e "${C_INFO}[INFO ]${C_RESET} $*"; }
ok()     { echo -e "${C_OK}[ OK  ]${C_RESET} $*"; }
warn()   { echo -e "${C_WARN}[WARN ]${C_RESET} $*"; }
err()    { echo -e "${C_ERR}[ERROR]${C_RESET} $*" >&2; exit 1; }

WORKDIR="/build/rpi5_build_env"
IMAGE_URL="https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2024-07-04/2024-07-04-raspios-bookworm-arm64-lite.img.xz"
IMAGE_XZ=$(basename "${IMAGE_URL}")
IMAGE_RAW="${IMAGE_XZ%.xz}"
MOUNT_DIR="${WORKDIR}/mnt"
CUSTOM_SCRIPT_HOST="/build/custom_customize.sh"
CUSTOM_SCRIPT_IMAGE="/custom_customize.sh"

# Ensure host volume exists
[[ -d /build ]] || err "Host directory /build not mounted. Use docker_build.sh."

download_and_verify() {
  log "Downloading base image..."
  if [[ -f "${IMAGE_XZ}" ]]; then
    warn "Found existing ${IMAGE_XZ}, skipping download."
  else
    wget -q --show-progress -O "${IMAGE_XZ}" "${IMAGE_URL}" || err "Download failed."
  fi
  log "Verifying checksum..."
  sha256sum "${IMAGE_XZ}" > "${IMAGE_XZ}.sha256"
  sha256sum --check --status "${IMAGE_XZ}.sha256" || err "Checksum mismatch."
  ok "Download & checksum OK."
}

extract_image() {
  log "Extracting ${IMAGE_XZ}..."
  xz -dkf "${IMAGE_XZ}" || err "Extraction failed."
  ok "Extracted to ${IMAGE_RAW}."
}

mount_image() {
  log "Mounting partitions..."
  mkdir -p "${MOUNT_DIR}"
  guestmount -a "${WORKDIR}/${IMAGE_RAW}" \
             -m /dev/sda2 \
             -m /dev/sda1:/boot/firmware \
             --pid-file "${MOUNT_DIR}.pid" \
             "${MOUNT_DIR}" || err "Mount failed."
  ok "Mounted at ${MOUNT_DIR}."
}

unmount_image() {
  log "Unmounting image..."
  guestunmount "${MOUNT_DIR}" || warn "guestunmount error"
  rm -f "${MOUNT_DIR}.pid"
  rmdir "${MOUNT_DIR}" 2>/dev/null || true
  ok "Unmounted."
}

clone_or_pull() {
  local url="$1" dir="$2" branch="${3:-main}"
  if [[ -d "${dir}" ]]; then
    log "Updating ${dir}..."
    (cd "${dir}" && git pull --ff-only) || err "git pull failed."
  else
    log "Cloning ${dir}..."
    git clone --depth 1 --branch "${branch}" "$1" "${dir}" || err "git clone failed."
  fi
  ok "${dir} ready."
}

kernel_workflow() {
  clone_or_pull https://github.com/raspberrypi/linux.git "${WORKDIR}/linux" rpi-6.6.y
  cd "${WORKDIR}/linux"
  log "Configuring kernel..."
  make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- bcm2712_defconfig || err
  make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- menuconfig || err
  log "Building kernel..."
  make -j"$(nproc)" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- 2>&1 | tee build.log || err
  mount_image
  make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
    INSTALL_MOD_PATH="${MOUNT_DIR}" modules_install || err
  cp arch/arm64/boot/Image.gz "${MOUNT_DIR}/boot/firmware/kernel_2712.img"
  cp arch/arm64/boot/dts/broadcom/*.dtb "${MOUNT_DIR}/boot/firmware/"
  cp arch/arm64/boot/dts/overlays/*.dtbo "${MOUNT_DIR}/boot/firmware/overlays/"
  unmount_image
  ok "Custom kernel installed."
}

firmware_workflow() {
  clone_or_pull https://github.com/raspberrypi/firmware.git "${WORKDIR}/firmware"
  mount_image
  rsync -a --delete "${WORKDIR}/firmware/boot/" "${MOUNT_DIR}/boot/firmware/" || err
  rsync -a --delete "${WORKDIR}/firmware/modules/" "${MOUNT_DIR}/lib/modules/" || err
  unmount_image
  ok "Firmware updated."
}

bootloader_workflow() {
  clone_or_pull https://github.com/raspberrypi/rpi-eeprom.git "${WORKDIR}/rpi-eeprom"
  cd "${WORKDIR}/rpi-eeprom"
  log "Building bootloader..."
  make -j"$(nproc)" || err
  mount_image
  cp firmwares/stable/pieeprom-*.bin "${MOUNT_DIR}/boot/firmware/"
  cp vl805/stable/vl805-*.bin "${MOUNT_DIR}/boot/firmware/"
  unmount_image
  ok "Bootloader installed."
}

secure_boot_workflow() {
  local keys="${WORKDIR}/secure-boot-keys"
  mkdir -p "${keys}"
  [[ -f "${keys}/ca_key.pem" ]] || {
    log "Generating Secure Boot keys..."
    openssl ecparam -name prime256v1 -genkey -noout -out "${keys}/ca_key.pem"
    openssl req -new -x509 -key "${keys}/ca_key.pem" \
      -out "${keys}/ca_cert.pem" -subj "/CN=Custom CA"
  }
  cd "${WORKDIR}/rpi-eeprom"
  log "Signing bootloader..."
  ./rpi-eeprom-digest -i firmwares/stable/pieeprom-*.bin \
    -o "${WORKDIR}/signed.bin" -k "${keys}/ca_key.pem" -c "${keys}/ca_cert.pem"
  mount_image
  cp "${WORKDIR}/signed.bin" "${MOUNT_DIR}/boot/firmware/pieeprom.bin"
  cp "${keys}/ca_cert.pem" "${MOUNT_DIR}/boot/firmware/"
  unmount_image
  ok "Secure Boot configured."
  warn "You must program OTP with your public key hash. This is irreversible."
}

package_customization() {
  mount_image
  log "Injecting QEMU and resolv.conf..."
  cp /usr/bin/qemu-aarch64-static "${MOUNT_DIR}/usr/bin/"
  cp /etc/resolv.conf "${MOUNT_DIR}/etc/"
  if [[ -f "${CUSTOM_SCRIPT_HOST}" ]]; then
    log "Using user customization script."
    cp "${CUSTOM_SCRIPT_HOST}" "${MOUNT_DIR}${CUSTOM_SCRIPT_IMAGE}"
  else
    log "Generating default customization script."
    cat > "${MOUNT_DIR}${CUSTOM_SCRIPT_IMAGE}" << _EOF_
#!/usr/bin/env bash
set -e
apt-get update && apt-get dist-upgrade -y
# User can drop a custom file at /build/custom_customize.sh
apt-get install -y neofetch htop
systemctl enable ssh
apt-get clean && rm -f /etc/resolv.conf
_EOF_
  fi
  chmod +x "${MOUNT_DIR}${CUSTOM_SCRIPT_IMAGE}"
  log "Running customization..."
  proot -S "${MOUNT_DIR}" /custom_customize.sh || err
  rm "${MOUNT_DIR}${CUSTOM_SCRIPT_IMAGE}" "${MOUNT_DIR}/usr/bin/qemu-aarch64-static"
  unmount_image
  ok "Package customization complete."
}

finalize_image() {
  cd "${WORKDIR}"
  local ts; ts=$(date +%Y%m%d_%H%M%S)
  local name="raspi5-custom_${ts}.img"
  mv "${IMAGE_RAW}" "${name}"
  log "Compressing final image..."
  xz -T0 -vf "${name}" || err
  sha256sum "${name}.xz" > "${name}.xz.sha256"
  ok "Final image: ${WORKDIR}/${name}.xz"
}

show_menu() {
  cat << MENU

${C_OK}==== Raspberry Pi 5 Image Builder ====${C_RESET}
1) Download & verify base image
2) Extract image
3) Kernel workflow
4) Firmware workflow
5) Bootloader workflow
6) Secure Boot workflow
7) Package customization
8) Finalize image
9) Run full pipeline (1→2→3→4→5→7→8)
q) Quit

MENU
}

main() {
  while true; do
    show_menu
    read -rp "Choice: " c
    case "$c" in
      1) download_and_verify    ;;
      2) extract_image         ;;
      3) kernel_workflow       ;;
      4) firmware_workflow     ;;
      5) bootloader_workflow   ;;
      6) secure_boot_workflow  ;;
      7) package_customization ;;
      8) finalize_image        ;;
      9) download_and_verify; extract_image; kernel_workflow; firmware_workflow; bootloader_workflow; package_customization; finalize_image ;;
      q|Q) exit 0              ;;
      *) warn "Invalid option." ;;
    esac
  done
}

main
EOF
chmod +x "${BUILD_SCRIPT}"
