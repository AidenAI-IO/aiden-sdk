#!/usr/bin/env bash
#
# vendor-android-tools.sh
#
# Reproducibly regenerate the vendored source tarball for the
# android-tools-aiden Buildroot package (modern adb client, reports
# version 1.0.41).
#
# The board build is offline / reproducible, so we cannot rely on
# Buildroot fetching git submodules from android.googlesource.com at
# build time. Instead we check out the pinned nmeum/android-tools
# release, init only the submodules the adb *client* needs, pre-apply
# the nmeum portability patches (exactly what nmeum's own release
# tarballs ship), prune everything the client does not build, and seal
# a deterministic tarball.
#
# Usage:
#   scripts/vendor-android-tools.sh [output-dir]
#
# The resulting tarball + sha256 go to:
#   <output-dir>/android-tools-aiden-<version>.tar.xz
# Copy it into:
#   sysdrv/source/buildroot/buildroot-2023.02.6/dl/android-tools-aiden/
# and update the package .hash file if the version changes.

set -euo pipefail

VERSION="30.0.5p1"          # nmeum/android-tools release tag (adb 1.0.41)
REPO="https://github.com/nmeum/android-tools.git"
PKG="android-tools-aiden-${VERSION}"
OUT_DIR="${1:-$(pwd)}"

# Submodules required to build only the adb client.
SUBMODULES=(
  vendor/core
  vendor/libbase
  vendor/libziparchive
  vendor/boringssl
)

# core/ subdirectories actually referenced by the adb client build.
CORE_KEEP=(
  adb diagnose_usb include libcrypto_utils libcutils
  liblog libutils libsystem base Android.bp
)

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo ">> cloning ${REPO} @ ${VERSION}"
git clone --quiet --depth 1 --branch "${VERSION}" "${REPO}" "${WORK}/at"
cd "${WORK}/at"

echo ">> initialising client submodules"
for sm in "${SUBMODULES[@]}"; do
  git submodule update --init --depth 1 "${sm}"
done

echo ">> pre-applying nmeum portability patches (core / libbase / libziparchive)"
for comp in core libbase libziparchive; do
  if compgen -G "patches/${comp}/*.patch" > /dev/null; then
    git -C "vendor/${comp}" -c user.email=build@aiden.local \
        -c user.name="aiden build" am --quiet ../../patches/${comp}/*.patch
  fi
done

echo ">> stripping git metadata"
find . -name .git -maxdepth 3 -exec rm -rf {} + 2>/dev/null || true
rm -rf .github patches

echo ">> defaulting ANDROID_TOOLS_PATCH_VENDOR OFF (sources already patched)"
sed -i \
  's/\(option(ANDROID_TOOLS_PATCH_VENDOR .*\) ON)/\1 OFF)/' \
  CMakeLists.txt

echo ">> trimming vendor build to adb client only"
python3 - <<'PY'
p = "vendor/CMakeLists.txt"
s = open(p).read()
s = s.replace(
    """include(CMakeLists.libbase.txt)
include(CMakeLists.libandroidfw.txt)
include(CMakeLists.adb.txt)
include(CMakeLists.sparse.txt)
include(CMakeLists.fastboot.txt)
include(CMakeLists.mke2fs.txt)""",
    """# Aiden: board uses adb client (host mode) only.
include(CMakeLists.libbase.txt)
include(CMakeLists.adb.txt)""")
s = s.replace(
    'install(TARGETS adb fastboot "${ANDROID_MKE2FS_NAME}"\n\tsimg2img img2simg append2simg DESTINATION bin)',
    "install(TARGETS adb DESTINATION bin)")
open(p, "w").write(s)
PY

echo ">> pruning unused vendor trees"
( cd vendor && rm -rf avb extras selinux mkbootimg native base e2fsprogs f2fs-tools )
( cd vendor/core
  for d in */; do
    name="${d%/}"
    keep=0
    for k in "${CORE_KEEP[@]}"; do [ "$k" = "$name" ] && keep=1; done
    [ "$keep" -eq 1 ] || rm -rf "$name"
  done )
( cd vendor/boringssl && rm -rf fuzz third_party/wycheproof_testvectors ssl/test 2>/dev/null || true )

echo ">> sealing reproducible tarball"
cd "${WORK}"
mv at "${PKG}"
tar --sort=name --mtime='2026-01-01 00:00:00' \
    --owner=0 --group=0 --numeric-owner \
    -cf "${PKG}.tar" "${PKG}"
xz -9 -e -T0 -f "${PKG}.tar"

mkdir -p "${OUT_DIR}"
mv "${PKG}.tar.xz" "${OUT_DIR}/"
cd "${OUT_DIR}"
sha256sum "${PKG}.tar.xz"
echo ">> done: ${OUT_DIR}/${PKG}.tar.xz"
