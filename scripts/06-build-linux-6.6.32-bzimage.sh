#!/bin/bash
set -euo pipefail

WS=/home/xtl/cxlfork-ws
SRC=${SRC:-${WS}/kernel/linux-6.6.32-cxlfork}
BUILD=${BUILD:-${WS}/kernel/build-6.6.32}
BASE_CONFIG=${BASE_CONFIG:-/boot/config-6.6.32-shm+}
JOBS=${JOBS:-$(nproc)}

mkdir -p "${BUILD}"
cp "${BASE_CONFIG}" "${BUILD}/.config"

"${SRC}/scripts/config" --file "${BUILD}/.config" \
  --set-str LOCALVERSION "-cxlfork" \
  --disable DEBUG_INFO_BTF \
  --disable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT \
  --disable SYSTEM_TRUSTED_KEYS \
  --disable SYSTEM_REVOCATION_KEYS \
  --enable BLK_DEV_PMEM \
  --enable ACPI_NFIT \
  --enable ND_BTT \
  --enable ND_PFN \
  --enable DEV_DAX \
  --enable DEV_DAX_PMEM \
  --enable DEV_DAX_KMEM \
  --enable NLS_CODEPAGE_437 \
  --enable NLS_ISO8859_1 \
  --enable ISO9660_FS \
  --enable CXLFORK

make -C "${SRC}" O="${BUILD}" olddefconfig
make -C "${SRC}" O="${BUILD}" -j"${JOBS}" bzImage

echo "[done] ${BUILD}/arch/x86/boot/bzImage"
file "${BUILD}/arch/x86/boot/bzImage"
