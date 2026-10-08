#!/bin/bash
set -Eeuo pipefail

###############################################################################
# Intel RealSense - Minimal Installation
# ROS 2 Humble / Docker Container / NVIDIA Jetson
#
# Installs:
#   - librealsense 2.58.1
#   - RSUSB backend
#
# Does NOT:
#   - patch the Jetson kernel
#   - install host kernel modules
#   - configure host udev
#   - install graphical tools
#   - install examples
#   - enable CUDA
#   - install realsense-ros
#
# The USB device must be exposed to the container by the host/runtime.
###############################################################################

LIBREALSENSE_VERSION="2.58.1"
REALSENSE_ROS_VERSION="4.58.1"
EXPECTED_FIRMWARE="5.17.3.10"

# Conservative default for Jetson containers with limited RAM.
BUILD_JOBS="${BUILD_JOBS:-1}"

WORK_ROOT="${WORK_ROOT:-/tmp/librealsense-build}"
SOURCE_DIR="${WORK_ROOT}/librealsense-${LIBREALSENSE_VERSION}"
BUILD_DIR="${SOURCE_DIR}/build"

INSTALL_MANIFEST_DIR="/usr/local/share/librealsense-source-install"
INSTALL_MANIFEST="${INSTALL_MANIFEST_DIR}/install_manifest.txt"

SOURCE_URL="https://github.com/realsenseai/librealsense/archive/refs/tags/v${LIBREALSENSE_VERSION}.zip"
SOURCE_ARCHIVE="${WORK_ROOT}/librealsense-${LIBREALSENSE_VERSION}.zip"

log() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

die() {
    echo
    echo "ERROR: $1" >&2
    exit 1
}

cleanup() {
    if [[ -d "${WORK_ROOT}" ]]; then
        rm -rf "${WORK_ROOT}"
    fi
}

trap cleanup EXIT

###############################################################################
# 1. Basic container validation
###############################################################################

log "Checking container environment"

if [[ ! -f /etc/os-release ]]; then
    die "Cannot determine operating system."
fi

source /etc/os-release

echo "OS:        ${PRETTY_NAME:-unknown}"
echo "Arch:      $(uname -m)"
echo "Kernel:    $(uname -r)"
echo "ROS_DISTRO: ${ROS_DISTRO:-not set}"

if [[ "${ID:-}" != "ubuntu" ]]; then
    die "This installer expects Ubuntu."
fi

if [[ "${VERSION_ID:-}" != "22.04" ]]; then
    echo "WARNING: ROS 2 Humble normally uses Ubuntu 22.04."
    echo "         Detected Ubuntu ${VERSION_ID:-unknown}."
fi

if [[ "$(uname -m)" != "aarch64" ]]; then
    echo "WARNING: Container architecture is not aarch64."
    echo "         Detected: $(uname -m)"
fi

if [[ "${ROS_DISTRO:-}" != "humble" ]]; then
    echo "WARNING: ROS_DISTRO is not 'humble'."
    echo "         Detected: ${ROS_DISTRO:-not set}"
fi

###############################################################################
# 2. Detect Docker/container
###############################################################################

if [[ -f /.dockerenv ]]; then
    echo "Container runtime: Docker"
else
    echo "WARNING: /.dockerenv not found."
    echo "         Continuing assuming this is a ROS 2 container."
fi

###############################################################################
# 3. Explain USB requirements
###############################################################################

log "Checking RealSense USB access"

if [[ -d /dev/bus/usb ]]; then
    echo "/dev/bus/usb is available inside the container."
else
    echo
    echo "WARNING: /dev/bus/usb is NOT available."
    echo
    echo "The librealsense library can still be compiled, but the"
    echo "D435i will not be accessible until USB is passed to the"
    echo "container."
    echo
    echo "Example Docker option:"
    echo
    echo "    --device=/dev/bus/usb"
    echo
fi

###############################################################################
# 4. Disk space
###############################################################################

log "Checking available disk space"

AVAILABLE_KB=$(df -Pk "${WORK_ROOT%/*}" 2>/dev/null | awk 'NR==2 {print $4}')

if [[ -n "${AVAILABLE_KB:-}" ]]; then
    AVAILABLE_GB=$((AVAILABLE_KB / 1024 / 1024))

    echo "Available space: ${AVAILABLE_GB} GiB"

    if (( AVAILABLE_KB < 1500000 )); then
        die "Less than ~1.5 GiB available for the source/build."
    fi
fi

###############################################################################
# 5. Dependencies
###############################################################################

log "Installing minimal build dependencies"

export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    libusb-1.0-0-dev \
    pkg-config \
    wget \
    unzip

###############################################################################
# 6. CMake version
###############################################################################

CMAKE_VERSION="$(cmake --version | awk 'NR==1 {print $3}')"

echo "CMake: ${CMAKE_VERSION}"

###############################################################################
# 7. Prepare build directory
###############################################################################

mkdir -p "${WORK_ROOT}"

rm -rf "${SOURCE_DIR}"
rm -f "${SOURCE_ARCHIVE}"

###############################################################################
# 8. Download librealsense
###############################################################################

log "Downloading librealsense ${LIBREALSENSE_VERSION}"

wget \
    --progress=dot:giga \
    -O "${SOURCE_ARCHIVE}" \
    "${SOURCE_URL}"

[[ -s "${SOURCE_ARCHIVE}" ]] || \
    die "Failed to download librealsense source."

###############################################################################
# 9. Extract
###############################################################################

log "Extracting librealsense"

unzip -q "${SOURCE_ARCHIVE}" -d "${WORK_ROOT}"

EXTRACTED_DIR="${WORK_ROOT}/librealsense-${LIBREALSENSE_VERSION}"

[[ -d "${EXTRACTED_DIR}" ]] || \
    die "Extracted librealsense directory not found."

###############################################################################
# 10. Verify source version
###############################################################################

log "Verifying librealsense source"

SOURCE_VERSION="$(
    grep -E 'REALSENSE_VERSION_STRING' \
        "${EXTRACTED_DIR}/CMakeLists.txt" 2>/dev/null \
        | head -n1 \
        || true
)"

echo "Source version check:"
echo "${SOURCE_VERSION:-not explicitly found}"

###############################################################################
# 11. Configure CMake
###############################################################################

log "Configuring librealsense"

mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DFORCE_RSUSB_BACKEND=ON \
    -DCHECK_FOR_UPDATES=OFF \
    -DENABLE_CCACHE=OFF \
    -DBUILD_WITH_CUDA=OFF \
    -DBUILD_WITH_OPENMP=OFF \
    -DBUILD_GLSL_EXTENSIONS=OFF \
    -DBUILD_UNIT_TESTS=OFF \
    -DBUILD_VIEWER_TESTS=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_GRAPHICAL_EXAMPLES=OFF \
    -DBUILD_CV_EXAMPLES=OFF \
    -DBUILD_DLIB_EXAMPLES=OFF \
    -DBUILD_PCL_EXAMPLES=OFF \
    -DBUILD_TOOLS=OFF \
    -DBUILD_PYTHON_BINDINGS=OFF \
    -DBUILD_LEGACY_PYBACKEND=OFF \
    -DBUILD_PYTHON_DOCS=OFF \
    -DBUILD_CSHARP_BINDINGS=OFF \
    -DBUILD_MATLAB_BINDINGS=OFF \
    -DBUILD_UNITY_BINDINGS=OFF \
    -DBUILD_OPENVINO_EXAMPLES=OFF \
    -DBUILD_OPEN3D_EXAMPLES=OFF \
    -DBUILD_OPENNI2_BINDINGS=OFF \
    -DBUILD_CV_KINFU_EXAMPLE=OFF \
    -DBUILD_PC_STITCHING=OFF \
    -DBUILD_WITH_DDS=OFF \
    -DBUILD_ROSBAG2=OFF \
    -DBUILD_RS2_ALL=OFF \
    -DBUILD_ASAN=OFF

###############################################################################
# 12. Validate configuration
###############################################################################

log "Validating CMake configuration"

grep -E \
    'FORCE_RSUSB_BACKEND|BUILD_WITH_CUDA|BUILD_EXAMPLES|BUILD_GRAPHICAL_EXAMPLES|BUILD_TOOLS' \
    CMakeCache.txt \
    || true

grep -q \
    'FORCE_RSUSB_BACKEND:BOOL=ON' \
    CMakeCache.txt \
    || die "RSUSB backend was not enabled."

grep -q \
    'BUILD_WITH_CUDA:BOOL=OFF' \
    CMakeCache.txt \
    || die "CUDA was unexpectedly enabled."

###############################################################################
# 13. Build
###############################################################################

log "Building librealsense"

echo "Build jobs: ${BUILD_JOBS}"

make -j"${BUILD_JOBS}"

###############################################################################
# 14. Verify build
###############################################################################

log "Verifying build"

if ! find "${BUILD_DIR}" -name 'librealsense2.so*' -print -quit \
    | grep -q .; then
    die "librealsense2.so was not generated."
fi

###############################################################################
# 15. Remove previous installation
###############################################################################

log "Removing previous source installation"

if [[ -f "${INSTALL_MANIFEST}" ]]; then

    while IFS= read -r file; do
        [[ -z "${file}" ]] && continue

        if [[ -e "${file}" || -L "${file}" ]]; then
            rm -f "${file}" || true
        fi
    done < "${INSTALL_MANIFEST}"

fi

###############################################################################
# 16. Install
###############################################################################

log "Installing librealsense"

make install

###############################################################################
# 17. Dynamic linker
###############################################################################

log "Updating dynamic linker"

ldconfig

###############################################################################
# 18. Save install manifest
###############################################################################

mkdir -p "${INSTALL_MANIFEST_DIR}"

if [[ -f "${BUILD_DIR}/install_manifest.txt" ]]; then
    cp \
        "${BUILD_DIR}/install_manifest.txt" \
        "${INSTALL_MANIFEST}"
fi

###############################################################################
# 19. Validate installation
###############################################################################

log "Validating installed librealsense"

if command -v pkg-config >/dev/null 2>&1; then

    INSTALLED_VERSION="$(
        pkg-config --modversion realsense2 2>/dev/null || true
    )

    echo "Installed version: ${INSTALLED_VERSION:-unknown}"

    if [[ "${INSTALLED_VERSION}" != "${LIBREALSENSE_VERSION}" ]]; then
        echo
        echo "WARNING:"
        echo "Expected: ${LIBREALSENSE_VERSION}"
        echo "Found:    ${INSTALLED_VERSION:-unknown}"
    fi

fi

###############################################################################
# 20. Check linker
###############################################################################

if ldconfig -p 2>/dev/null | grep -q 'librealsense2.so'; then
    echo "librealsense2 is visible to ldconfig."
else
    echo "WARNING: librealsense2 was not found by ldconfig."
fi

###############################################################################
# 21. Final configuration
###############################################################################

log "Installation completed"

echo "librealsense version : ${LIBREALSENSE_VERSION}"
echo "realsense-ros target  : ${REALSENSE_ROS_VERSION}"
echo "Expected firmware     : ${EXPECTED_FIRMWARE}"
echo "Backend               : RSUSB"
echo "CUDA                  : OFF"
echo "OpenMP                : OFF"
echo "Examples              : OFF"
echo "Viewer                : OFF"
echo "Tools                 : OFF"
echo "Python bindings       : OFF"
echo "Build jobs            : ${BUILD_JOBS}"

echo
echo "IMPORTANT:"
echo
echo "This installation was performed INSIDE the container."
echo
echo "The script intentionally does NOT:"
echo "  - patch the Jetson kernel"
echo "  - install RealSense kernel modules"
echo "  - modify host udev rules"
echo "  - flash D435i firmware"
echo
echo "The host/container runtime must expose the D435i USB device."
echo
echo "After this installation, build realsense-ros against this"
echo "librealsense installation."
echo

###############################################################################
# 22. Optional cleanup
###############################################################################

rm -f "${SOURCE_ARCHIVE}"

echo "Temporary build files will be removed."
echo "Done."