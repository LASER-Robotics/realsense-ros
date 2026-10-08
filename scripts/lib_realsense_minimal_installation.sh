#!/bin/bash
set -Eeuo pipefail

# ============================================================
# RealSense - Librealsense MINIMAL installer for robots
#
# Stack alvo:
#   D435i firmware : 5.17.3.10
#   librealsense   : 2.58.1
#   realsense-ros  : 4.58.1
#   backend        : RSUSB
#
# Objetivo:
#   Instalar somente o necessário para o realsense-ros usar
#   a D435i nos robôs.
#
# DESABILITADO:
#   - CUDA
#   - DDS
#   - ROSBag2
#   - realsense-viewer
#   - tools
#   - examples
#   - GLSL/OpenGL
#   - Python/C#/MATLAB/Unity bindings
#   - OpenCV/PCL/DLIB/Open3D/OpenVINO examples
#   - unit tests
#   - update checker
#
# MANTIDO:
#   - librealsense2 shared library
#   - headers
#   - RSUSB/libusb backend
#   - CPU optimizations (NEON em ARM64 quando suportado)
#
# Uso:
#   ./install_minimal.sh
#
# Opcional:
#   BUILD_JOBS=1 ./install_minimal.sh
#   BUILD_JOBS=2 ./install_minimal.sh
#
# Para Jetson Nano recomenda-se BUILD_JOBS=2 ou 1 se faltar RAM.
# ============================================================

LIBREALSENSE_VERSION="2.58.1"
REALSENSE_ROS_VERSION="4.58.1"
EXPECTED_FIRMWARE="5.17.3.10"

BUILD_JOBS="${BUILD_JOBS:-2}"

DOWNLOAD_URL="https://github.com/realsenseai/librealsense/archive/refs/tags/v${LIBREALSENSE_VERSION}.zip"

# Build temporário: será apagado ao final para economizar espaço.
WORK_ROOT="$(mktemp -d /tmp/librealsense-minimal.XXXXXX)"
DOWNLOAD_FILE="${WORK_ROOT}/librealsense-${LIBREALSENSE_VERSION}.zip"
SOURCE_DIR="${WORK_ROOT}/librealsense-${LIBREALSENSE_VERSION}"
BUILD_DIR="${SOURCE_DIR}/build"

# Manifesto persistente para permitir upgrade/uninstall futuro,
# mesmo depois de apagarmos o diretório de build.
PERSIST_DIR="/usr/local/share/librealsense-source-install"
PERSIST_MANIFEST="${PERSIST_DIR}/install_manifest.txt"
OLD_MANIFEST="${WORK_ROOT}/old_install_manifest.txt"

# ============================================================
# Helpers
# ============================================================

if [ "${EUID}" -eq 0 ]; then
    SUDO=()
else
    SUDO=(sudo)
fi

run_root()
{
    "${SUDO[@]}" "$@"
}

cleanup()
{
    rm -rf "${WORK_ROOT}"
}

trap cleanup EXIT

echo
echo "============================================================"
echo " RealSense MINIMAL installer"
echo "============================================================"
echo " librealsense : ${LIBREALSENSE_VERSION}"
echo " realsense-ros: ${REALSENSE_ROS_VERSION}"
echo " firmware alvo: ${EXPECTED_FIRMWARE}"
echo " backend      : RSUSB"
echo " CUDA         : OFF"
echo " DDS          : OFF"
echo " ROSBag2      : OFF"
echo " Viewer       : OFF"
echo " Tools        : OFF"
echo " Examples     : OFF"
echo " GLSL         : OFF"
echo " Updates      : OFF"
echo " build jobs   : ${BUILD_JOBS}"
echo "============================================================"
echo

if [ "${EUID}" -ne 0 ]; then
    sudo -v
fi

if command -v lsb_release >/dev/null 2>&1; then
    lsb_release -a || true
fi

echo "Kernel version: $(uname -r)"
echo "Architecture:   $(uname -m)"
echo

IN_DOCKER=false

if [ -f /.dockerenv ]; then
    IN_DOCKER=true
    echo "Docker container detected."
    echo
fi

# ============================================================
# Dependências MÍNIMAS de compilação
#
# Não instalamos:
#   git, GTK, GLFW, Mesa, GLUT, CUDA, curl, OpenSSL-dev, etc.
#
# libudev-dev também é omitido propositalmente: ele é opcional.
# Sem ele a SDK usa polling para detecção USB.
# ============================================================

echo "Installing minimal build dependencies..."

run_root apt-get update

run_root apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    libusb-1.0-0-dev \
    pkg-config \
    wget \
    unzip

# ============================================================
# Guardar manifesto da instalação anterior
#
# IMPORTANTE:
# A versão anterior ainda NÃO é removida.
# Primeiro compilamos a nova.
# ============================================================

echo
echo "Looking for a previous source installation manifest..."

: > "${OLD_MANIFEST}"

# Manifesto criado por este instalador minimal/full atualizado.
if [ -f "${PERSIST_MANIFEST}" ]; then
    cat "${PERSIST_MANIFEST}" >> "${OLD_MANIFEST}"
fi

# Compatibilidade com os scripts antigos que mantinham o build.
SEARCH_ROOTS=()

[ -d "${HOME}/librealsense_build" ] && \
    SEARCH_ROOTS+=("${HOME}/librealsense_build")

[ -d /root/librealsense_build ] && \
    SEARCH_ROOTS+=(/root/librealsense_build)

if [ -d /home ]; then
    while IFS= read -r dir; do
        SEARCH_ROOTS+=("${dir}")
    done < <(
        find /home \
            -maxdepth 2 \
            -type d \
            -name librealsense_build \
            -print 2>/dev/null || true
    )
fi

if [ "${#SEARCH_ROOTS[@]}" -gt 0 ]; then

    mapfile -t FOUND_MANIFESTS < <(
        find "${SEARCH_ROOTS[@]}" \
            -type f \
            -name install_manifest.txt \
            -print 2>/dev/null || true
    )

    for manifest in "${FOUND_MANIFESTS[@]}"; do
        echo "Found old manifest:"
        echo "  ${manifest}"
        cat "${manifest}" >> "${OLD_MANIFEST}"
    done
fi

if [ -s "${OLD_MANIFEST}" ]; then
    sort -u "${OLD_MANIFEST}" -o "${OLD_MANIFEST}"
    echo "[OK] Previous install manifest preserved."
else
    echo "No previous install manifest found."
fi

EXISTING_VERSION=""
EXISTING_PREFIX=""

if pkg-config --exists realsense2 2>/dev/null; then
    EXISTING_VERSION="$(pkg-config --modversion realsense2)"
    EXISTING_PREFIX="$(pkg-config --variable=prefix realsense2)"

    echo
    echo "Existing librealsense:"
    echo "  version: ${EXISTING_VERSION}"
    echo "  prefix : ${EXISTING_PREFIX}"
fi

# ============================================================
# Download da versão EXATA
# ============================================================

echo
echo "Downloading librealsense v${LIBREALSENSE_VERSION}..."

wget \
    --no-verbose \
    "${DOWNLOAD_URL}" \
    -O "${DOWNLOAD_FILE}"

unzip -q "${DOWNLOAD_FILE}" -d "${WORK_ROOT}"

cd "${SOURCE_DIR}"

# ============================================================
# Validar versão do source
# ============================================================

RS_MAJOR="$(
    awk '/^#define RS2_API_MAJOR_VERSION/ {print $3; exit}' \
        include/librealsense2/rs.h
)"

RS_MINOR="$(
    awk '/^#define RS2_API_MINOR_VERSION/ {print $3; exit}' \
        include/librealsense2/rs.h
)"

RS_PATCH="$(
    awk '/^#define RS2_API_PATCH_VERSION/ {print $3; exit}' \
        include/librealsense2/rs.h
)"

SOURCE_VERSION="${RS_MAJOR}.${RS_MINOR}.${RS_PATCH}"

echo "Source version: ${SOURCE_VERSION}"

if [ "${SOURCE_VERSION}" != "${LIBREALSENSE_VERSION}" ]; then
    echo "ERROR: expected ${LIBREALSENSE_VERSION}, got ${SOURCE_VERSION}."
    exit 1
fi

# ============================================================
# Configurar build MINIMAL
# ============================================================

mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

echo
echo "Configuring minimal librealsense build..."

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

# ============================================================
# Validar opções essenciais
# ============================================================

echo
echo "Validating minimal CMake configuration..."

declare -A EXPECTED_OPTIONS=(
    [BUILD_SHARED_LIBS]=ON
    [FORCE_RSUSB_BACKEND]=ON
    [CHECK_FOR_UPDATES]=OFF
    [BUILD_WITH_CUDA]=OFF
    [BUILD_GLSL_EXTENSIONS]=OFF
    [BUILD_UNIT_TESTS]=OFF
    [BUILD_EXAMPLES]=OFF
    [BUILD_GRAPHICAL_EXAMPLES]=OFF
    [BUILD_TOOLS]=OFF
    [BUILD_PYTHON_BINDINGS]=OFF
    [BUILD_WITH_DDS]=OFF
    [BUILD_ROSBAG2]=OFF
    [BUILD_RS2_ALL]=OFF
)

for option in "${!EXPECTED_OPTIONS[@]}"; do

    expected="${EXPECTED_OPTIONS[$option]}"

    if grep -q "^${option}:BOOL=${expected}$" CMakeCache.txt; then
        echo "[OK] ${option}=${expected}"
    else
        echo
        echo "ERROR: ${option} should be ${expected}"
        grep "^${option}:" CMakeCache.txt || true
        echo
        echo "Previous librealsense installation was NOT removed."
        exit 1
    fi
done

# ============================================================
# Compilar PRIMEIRO
# ============================================================

echo
echo "Building minimal librealsense with ${BUILD_JOBS} jobs..."

make -j"${BUILD_JOBS}"

# Confirmar que a shared library realmente foi gerada.
if ! find "${BUILD_DIR}" \
        -type f \
        \( -name 'librealsense2.so' -o -name 'librealsense2.so.*' \) \
        -print -quit |
     grep -q .; then

    echo
    echo "ERROR: librealsense2 shared library was not generated."
    echo "Previous installation was NOT removed."
    exit 1
fi

echo
echo "[OK] New minimal build completed successfully."
echo "[OK] Previous installation can now be replaced."

# ============================================================
# SOMENTE AGORA desinstalar a versão anterior
# ============================================================

if [ -s "${OLD_MANIFEST}" ]; then

    echo
    echo "Removing previous source installation..."

    while IFS= read -r installed_file; do

        [ -n "${installed_file}" ] || continue

        if [ -e "${installed_file}" ] || [ -L "${installed_file}" ]; then
            run_root rm -f -- "${installed_file}"
        fi

    done < "${OLD_MANIFEST}"

    run_root ldconfig

else

    # Não sobrescrever instalação manual desconhecida.
    if [ "${EXISTING_PREFIX}" = "/usr/local" ]; then

        echo
        echo "ERROR:"
        echo "A librealsense installation exists in /usr/local"
        echo "but no install_manifest.txt was found."
        echo
        echo "Detected version: ${EXISTING_VERSION}"
        echo "The new build succeeded, but installation was not performed."
        exit 1
    fi
fi

# ============================================================
# udev rules
# ============================================================

echo
echo "Installing RealSense udev rules..."

cd "${SOURCE_DIR}"

if [ "${IN_DOCKER}" = true ]; then

    echo
    echo "WARNING:"
    echo "Running inside Docker."
    echo "udev rules must be installed on the ROBOT HOST."
    echo
    echo "Host files:"
    echo "  config/99-realsense-libusb.rules"
    echo "  config/99-realsense-d4xx-mipi-dfu.rules"
    echo

else

    run_root cp \
        config/99-realsense-libusb.rules \
        /etc/udev/rules.d/

    run_root cp \
        config/99-realsense-d4xx-mipi-dfu.rules \
        /etc/udev/rules.d/

    run_root udevadm control --reload-rules
    run_root udevadm trigger
fi

# ============================================================
# Instalar
# ============================================================

cd "${BUILD_DIR}"

echo
echo "Installing minimal librealsense..."

run_root make install
run_root ldconfig

# Guardar manifesto fora do build antes de apagá-lo.
run_root mkdir -p "${PERSIST_DIR}"
run_root cp \
    "${BUILD_DIR}/install_manifest.txt" \
    "${PERSIST_MANIFEST}"

# ============================================================
# Validar instalação
# ============================================================

echo
echo "Validating installation..."

INSTALLED_VERSION="$(pkg-config --modversion realsense2)"

if [ "${INSTALLED_VERSION}" != "${LIBREALSENSE_VERSION}" ]; then
    echo "ERROR:"
    echo "Expected ${LIBREALSENSE_VERSION}, got ${INSTALLED_VERSION}."
    exit 1
fi

# Consumir toda a saída evita SIGPIPE no ldconfig com pipefail ativo.
if ! ldconfig -p | grep 'librealsense2\.so' > /dev/null; then
    echo "ERROR: librealsense2 was not found by ldconfig."
    exit 1
fi

# Como este é o minimal, estas ferramentas NÃO devem ser exigidas.
echo
echo "============================================================"
echo " RealSense MINIMAL installation completed"
echo "============================================================"
echo " librealsense : ${INSTALLED_VERSION}"
echo " realsense-ros: ${REALSENSE_ROS_VERSION}"
echo " backend      : RSUSB"
echo " shared lib   : ON"
echo " headers      : ON"
echo " CUDA         : OFF"
echo " DDS          : OFF"
echo " ROSBag2      : OFF"
echo " Viewer       : OFF"
echo " Tools        : OFF"
echo " Examples     : OFF"
echo " GLSL         : OFF"
echo " Updates      : OFF"
echo "============================================================"
echo

echo "This installation is intended for the robot ROS 2 runtime."
echo
echo "Rebuild realsense-ros after changing librealsense:"
echo "  librealsense ${LIBREALSENSE_VERSION}"
echo "  realsense-ros ${REALSENSE_ROS_VERSION}"
echo
echo "Persistent uninstall manifest:"
echo "  ${PERSIST_MANIFEST}"
echo