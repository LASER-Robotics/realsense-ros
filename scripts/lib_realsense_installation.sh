#!/bin/bash
set -Eeuo pipefail

# ============================================================
# RealSense - Librealsense full installer
#
# Stack alvo:
#   D435i firmware : 5.17.3.10
#   librealsense   : 2.58.1
#   realsense-ros  : 4.58.1
#   backend        : RSUSB
#
# Política:
#   - Viewer / GLSL / Tools / Examples / RSUSB: obrigatórios
#   - CUDA: AUTO (ON se funcional e compatível; OFF se não)
#   - DDS: AUTO (ON se suportado; fallback para OFF)
#   - ROSBag2: AUTO (ON inicialmente; fallback para OFF)
#   - CHECK_FOR_UPDATES: ON inicialmente; fallback para OFF
#   - A instalação antiga só é removida DEPOIS de a nova
#     configuração compilar com sucesso.
#
# Uso:
#   ./lib_realsense_installation.sh
#
# Opcional:
#   BUILD_JOBS=4 ./lib_realsense_installation.sh
#
# Jetson Nano:
#   BUILD_JOBS=2 ./lib_realsense_installation.sh
#
# Para apontar manualmente para um CUDA:
#   CUDA_ROOT_OVERRIDE=/usr/local/cuda-13.0 ./lib_realsense_installation.sh
# ============================================================

LIBREALSENSE_VERSION="2.58.1"
REALSENSE_ROS_VERSION="4.58.1"
EXPECTED_FIRMWARE="5.17.3.10"

BUILD_ROOT="${HOME}/librealsense_build"
SOURCE_DIR="${BUILD_ROOT}/librealsense-${LIBREALSENSE_VERSION}"
BUILD_DIR="${SOURCE_DIR}/build"

DOWNLOAD_FILE="${BUILD_ROOT}/librealsense-${LIBREALSENSE_VERSION}.zip"
DOWNLOAD_URL="https://github.com/realsenseai/librealsense/archive/refs/tags/v${LIBREALSENSE_VERSION}.zip"

PREVIOUS_MANIFEST="${BUILD_ROOT}/.previous_install_manifest.txt"
CMAKE_LOG="${BUILD_ROOT}/cmake_configure.log"
BUILD_LOG="${BUILD_ROOT}/build.log"

BUILD_JOBS="${BUILD_JOBS:-2}"

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

version_ge()
{
    dpkg --compare-versions "$1" ge "$2"
}

cleanup_cuda_test()
{
    if [ -n "${CUDA_TEST_DIR:-}" ] && [ -d "${CUDA_TEST_DIR}" ]; then
        rm -rf "${CUDA_TEST_DIR}"
    fi
}

trap cleanup_cuda_test EXIT

echo
echo "============================================================"
echo " RealSense full installer"
echo "============================================================"
echo " librealsense : ${LIBREALSENSE_VERSION}"
echo " realsense-ros: ${REALSENSE_ROS_VERSION}"
echo " firmware alvo: ${EXPECTED_FIRMWARE}"
echo " backend      : RSUSB"
echo " CUDA         : AUTO"
echo " DDS          : AUTO"
echo " ROSBag2      : AUTO"
echo " Viewer       : ON"
echo " Examples     : ON"
echo " GLSL         : ON"
echo " Tools        : ON"
echo " RS2_ALL      : ON"
echo " Updates      : ON (fallback OFF se necessário)"
echo " build jobs   : ${BUILD_JOBS}"
echo "============================================================"
echo

if [ "${EUID}" -ne 0 ]; then
    sudo -v
fi

# ============================================================
# Informações do sistema
# ============================================================

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
# Dependências
# ============================================================

echo
echo "Installing librealsense build dependencies..."

run_root apt-get update

run_root apt-get install -y \
    build-essential \
    git \
    cmake \
    libssl-dev \
    libusb-1.0-0-dev \
    libudev-dev \
    pkg-config \
    wget \
    unzip \
    curl \
    libcurl4-openssl-dev \
    libgtk-3-dev \
    libglfw3-dev \
    libgl1-mesa-dev \
    libglu1-mesa-dev \
    freeglut3-dev \
    usbutils \
    file

# ============================================================
# Detectar RealSense conectada
# ============================================================

if command -v lsusb >/dev/null 2>&1 &&
   lsusb | grep -qiE 'RealSense|Intel.*8086:'; then

    echo -e "\e[33m"
    echo "A USB device from Intel/RealSense was detected."
    echo "Disconnect the RealSense camera before continuing."
    read -r -p "Press ENTER when ready..."
    echo -e "\e[0m"
fi

# ============================================================
# CMake / DDS AUTO
# ============================================================

echo
echo "Checking CMake..."

cmake --version

CMAKE_VERSION="$(
    cmake --version |
    head -n1 |
    awk '{print $3}'
)"

BUILD_WITH_DDS="ON"

if version_ge "${CMAKE_VERSION}" "3.16.3"; then
    echo "[OK] CMake ${CMAKE_VERSION}"
    echo "[OK] DDS can be enabled."
else
    echo
    echo "[WARNING] CMake ${CMAKE_VERSION} < 3.16.3."
    echo "[WARNING] BUILD_WITH_DDS=OFF."
    BUILD_WITH_DDS="OFF"
fi

# ROSBag2 começa ligado e pode cair para OFF se FastCDR/FastDDS falhar.
BUILD_ROSBAG2="ON"

# CHECK_FOR_UPDATES começa ligado e pode cair para OFF se curl falhar.
CHECK_FOR_UPDATES="ON"

# ============================================================
# CUDA AUTO
# ============================================================

echo
echo "Checking CUDA..."

BUILD_WITH_CUDA="OFF"
CUDA_NVCC=""
CUDA_ROOT=""
CUDA_VERSION=""
CMAKE_CUDA_ARGS=()

# Jetson Nano: a configuração CUDA padrão da librealsense 2.58.1
# não inclui a arquitetura Maxwell SM 5.3. Para evitar um build
# que compile mas não seja útil no Nano, desabilitamos CUDA.
JETSON_MODEL=""

if [ -r /proc/device-tree/model ]; then
    JETSON_MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || true)"
fi

if echo "${JETSON_MODEL}" | grep -qi 'Jetson Nano'; then

    echo "[INFO] Jetson Nano detected: ${JETSON_MODEL}"
    echo "[WARNING] CUDA support disabled for librealsense ${LIBREALSENSE_VERSION} on Jetson Nano."
    BUILD_WITH_CUDA="OFF"

else

    # Prioridade:
    #   1. CUDA_ROOT_OVERRIDE
    #   2. /usr/local/cuda
    #   3. versão mais nova em /usr/local/cuda-*
    #   4. nvcc no PATH

    if [ -n "${CUDA_ROOT_OVERRIDE:-}" ] &&
       [ -x "${CUDA_ROOT_OVERRIDE}/bin/nvcc" ]; then

        CUDA_ROOT="${CUDA_ROOT_OVERRIDE}"
        CUDA_NVCC="${CUDA_ROOT}/bin/nvcc"

    elif [ -x /usr/local/cuda/bin/nvcc ]; then

        CUDA_ROOT="/usr/local/cuda"
        CUDA_NVCC="${CUDA_ROOT}/bin/nvcc"

    else
        mapfile -t CUDA_CANDIDATES < <(
            find /usr/local \
                -maxdepth 2 \
                -type f \
                -path '/usr/local/cuda-*/bin/nvcc' \
                -print 2>/dev/null |
            sort -V
        )

        if [ "${#CUDA_CANDIDATES[@]}" -gt 0 ]; then
            CUDA_NVCC="${CUDA_CANDIDATES[-1]}"
            CUDA_ROOT="$(dirname "$(dirname "${CUDA_NVCC}")")"

        elif command -v nvcc >/dev/null 2>&1; then
            CUDA_NVCC="$(command -v nvcc)"
            CUDA_NVCC_REAL="$(readlink -f "${CUDA_NVCC}")"
            CUDA_ROOT="$(dirname "$(dirname "${CUDA_NVCC_REAL}")")"
        fi
    fi

    if [ -z "${CUDA_NVCC}" ]; then

        echo "[WARNING] CUDA Toolkit was not found."
        echo "[WARNING] Continuing with BUILD_WITH_CUDA=OFF."

    else

        echo "CUDA compiler candidate:"
        echo "  ${CUDA_NVCC}"

        CUDA_VERSION="$(
            "${CUDA_NVCC}" --version 2>/dev/null |
            sed -n 's/.*release \([0-9.]*\).*/\1/p' |
            head -n1
        )"

        if [ -n "${CUDA_VERSION}" ]; then
            echo "CUDA Toolkit version:"
            echo "  ${CUDA_VERSION}"
        else
            echo "[WARNING] CUDA Toolkit version could not be detected."
        fi

        CUDA_COMPATIBLE=true

        # RTX 50 / Blackwell precisa de um toolkit recente.
        GPU_NAME=""

        if command -v nvidia-smi >/dev/null 2>&1; then
            GPU_NAME="$(
                nvidia-smi \
                    --query-gpu=name \
                    --format=csv,noheader 2>/dev/null |
                head -n1 || true
            )"
        fi

        if echo "${GPU_NAME}" | grep -qiE 'RTX 50|Blackwell'; then

            echo "Detected Blackwell-class GPU:"
            echo "  ${GPU_NAME}"

            if [ -z "${CUDA_VERSION}" ] ||
               ! version_ge "${CUDA_VERSION}" "12.8"; then

                echo
                echo "[WARNING] CUDA >= 12.8 is required for RTX 50 / Blackwell."
                echo "[WARNING] Detected CUDA: ${CUDA_VERSION:-unknown}"
                echo "[WARNING] Continuing with BUILD_WITH_CUDA=OFF."

                CUDA_COMPATIBLE=false
            fi
        fi

        if [ "${CUDA_COMPATIBLE}" = true ]; then

            CUDA_TEST_DIR="$(mktemp -d)"

            cat > "${CUDA_TEST_DIR}/cuda_test.cu" <<'EOF'
__global__ void test_kernel()
{
}

int main()
{
    return 0;
}
EOF

            if "${CUDA_NVCC}" \
                -c "${CUDA_TEST_DIR}/cuda_test.cu" \
                -o "${CUDA_TEST_DIR}/cuda_test.o" \
                >"${CUDA_TEST_DIR}/stdout.log" \
                2>"${CUDA_TEST_DIR}/stderr.log"; then

                BUILD_WITH_CUDA="ON"

                echo
                echo "[OK] CUDA compiler is functional."
                echo "[OK] BUILD_WITH_CUDA=ON"

                export CUDACXX="${CUDA_NVCC}"

                if [ -d "${CUDA_ROOT}/bin" ]; then
                    export PATH="${CUDA_ROOT}/bin:${PATH}"
                fi

                if [ -d "${CUDA_ROOT}/lib64" ]; then
                    export LD_LIBRARY_PATH="${CUDA_ROOT}/lib64:${LD_LIBRARY_PATH:-}"
                fi

                CMAKE_CUDA_ARGS=(
                    "-DCMAKE_CUDA_COMPILER=${CUDA_NVCC}"
                    "-DCUDA_TOOLKIT_ROOT_DIR=${CUDA_ROOT}"
                )

            else

                echo
                echo "[WARNING] CUDA was found, but nvcc cannot compile."
                echo "CUDA compiler:"
                echo "  ${CUDA_NVCC}"
                echo

                cat "${CUDA_TEST_DIR}/stderr.log" || true

                echo
                echo "[WARNING] Continuing with BUILD_WITH_CUDA=OFF."

                BUILD_WITH_CUDA="OFF"
                CUDA_NVCC=""
                CUDA_ROOT=""
                CMAKE_CUDA_ARGS=()
            fi

            rm -rf "${CUDA_TEST_DIR}"
            CUDA_TEST_DIR=""
        fi
    fi
fi

echo
echo "CUDA build status: ${BUILD_WITH_CUDA}"

# ============================================================
# Swap para máquinas com pouca RAM
# ============================================================

MEM_TOTAL_KB="$(
    awk '/MemTotal/ {print $2}' /proc/meminfo
)"

if [ "${MEM_TOTAL_KB}" -lt 8000000 ]; then

    if [ "${IN_DOCKER}" = true ]; then

        echo
        echo "Low-memory system detected inside Docker."
        echo "If compilation runs out of RAM, configure swap on the HOST."

    elif [ "$(run_root swapon --show --noheadings | wc -l)" -eq 0 ]; then

        echo
        echo "No active swap detected."
        echo "Creating 2 GiB swap file..."

        if [ ! -f /swapfile ]; then
            run_root fallocate -l 2G /swapfile
        fi

        run_root chmod 600 /swapfile

        if ! run_root file /swapfile | grep -q "swap file"; then
            run_root mkswap /swapfile
        fi

        run_root swapon /swapfile || true
        run_root swapon --show
    fi
fi

# ============================================================
# Preservar manifesto da instalação anterior
#
# IMPORTANTE:
# Ainda NÃO removemos a instalação atual.
# ============================================================

echo
echo "Checking previous librealsense installation..."

mkdir -p "${BUILD_ROOT}"

rm -f "${PREVIOUS_MANIFEST}"

mapfile -t OLD_MANIFESTS < <(
    find "${BUILD_ROOT}" \
        -type f \
        -name install_manifest.txt \
        -print 2>/dev/null || true
)

if [ "${#OLD_MANIFESTS[@]}" -gt 0 ]; then

    echo "Previous install manifests found:"

    for manifest in "${OLD_MANIFESTS[@]}"; do
        echo "  ${manifest}"
        cat "${manifest}" >> "${PREVIOUS_MANIFEST}"
    done

    sort -u "${PREVIOUS_MANIFEST}" -o "${PREVIOUS_MANIFEST}"

    echo
    echo "[OK] Previous install manifest backed up to:"
    echo "  ${PREVIOUS_MANIFEST}"

else
    echo "No previous install_manifest.txt found."
fi

EXISTING_MANUAL_PREFIX=""
EXISTING_MANUAL_VERSION=""

if command -v pkg-config >/dev/null 2>&1 &&
   pkg-config --exists realsense2 2>/dev/null; then

    EXISTING_MANUAL_VERSION="$(pkg-config --modversion realsense2)"
    EXISTING_MANUAL_PREFIX="$(pkg-config --variable=prefix realsense2)"

    echo
    echo "Existing librealsense detected:"
    echo "  version: ${EXISTING_MANUAL_VERSION}"
    echo "  prefix : ${EXISTING_MANUAL_PREFIX}"
fi

# ============================================================
# Preparar fonte NOVA sem remover a instalação funcional
# ============================================================

echo
echo "Preparing clean source/build tree..."

rm -rf "${SOURCE_DIR}"
rm -f "${DOWNLOAD_FILE}"

cd "${BUILD_ROOT}"

echo
echo "Downloading librealsense v${LIBREALSENSE_VERSION}..."

wget \
    "${DOWNLOAD_URL}" \
    -O "${DOWNLOAD_FILE}"

unzip -q \
    "${DOWNLOAD_FILE}" \
    -d "${BUILD_ROOT}"

cd "${SOURCE_DIR}"

# ============================================================
# Validar versão do source
# ============================================================

RS_MAJOR="$(
    awk \
        '/^#define RS2_API_MAJOR_VERSION/ {print $3; exit}' \
        include/librealsense2/rs.h
)"

RS_MINOR="$(
    awk \
        '/^#define RS2_API_MINOR_VERSION/ {print $3; exit}' \
        include/librealsense2/rs.h
)"

RS_PATCH="$(
    awk \
        '/^#define RS2_API_PATCH_VERSION/ {print $3; exit}' \
        include/librealsense2/rs.h
)"

SOURCE_VERSION="${RS_MAJOR}.${RS_MINOR}.${RS_PATCH}"

echo
echo "Source version detected: ${SOURCE_VERSION}"

if [ "${SOURCE_VERSION}" != "${LIBREALSENSE_VERSION}" ]; then
    echo
    echo "ERROR:"
    echo "Expected librealsense ${LIBREALSENSE_VERSION}"
    echo "Downloaded source reports ${SOURCE_VERSION}"
    exit 1
fi

# ============================================================
# Configurar + compilar com fallbacks
#
# Ordem dos fallbacks:
#   CUDA       -> OFF em erro CUDA
#   DDS/ROSBag -> OFF em erro FastDDS/FastCDR
#   Updates    -> OFF em erro curl
#
# Viewer/GLSL/Tools NÃO têm fallback: são obrigatórios.
# ============================================================

configure_and_build()
{
    rm -rf "${BUILD_DIR}"
    mkdir -p "${BUILD_DIR}"

    cd "${BUILD_DIR}"

    : > "${CMAKE_LOG}"
    : > "${BUILD_LOG}"

    echo
    echo "Configuring librealsense..."
    echo "  CUDA        : ${BUILD_WITH_CUDA}"
    echo "  DDS         : ${BUILD_WITH_DDS}"
    echo "  ROSBag2     : ${BUILD_ROSBAG2}"
    echo "  Updates     : ${CHECK_FOR_UPDATES}"
    echo "  Viewer      : ON"
    echo "  GLSL        : ON"
    echo "  Tools       : ON"
    echo

    CMAKE_ARGS=(
        ..
        "-DFORCE_RSUSB_BACKEND=ON"
        "-DCMAKE_BUILD_TYPE=Release"
        "-DCHECK_FOR_UPDATES=${CHECK_FOR_UPDATES}"
        "-DBUILD_EXAMPLES=ON"
        "-DBUILD_GRAPHICAL_EXAMPLES=ON"
        "-DBUILD_GLSL_EXTENSIONS=ON"
        "-DBUILD_TOOLS=ON"
        "-DBUILD_ROSBAG2=${BUILD_ROSBAG2}"
        "-DBUILD_RS2_ALL=ON"
        "-DBUILD_WITH_DDS=${BUILD_WITH_DDS}"
        "-DBUILD_WITH_CUDA=${BUILD_WITH_CUDA}"
    )

    if [ "${BUILD_WITH_CUDA}" = "ON" ]; then
        CMAKE_ARGS+=("${CMAKE_CUDA_ARGS[@]}")
    fi

    if ! cmake "${CMAKE_ARGS[@]}" 2>&1 | tee "${CMAKE_LOG}"; then
        return 10
    fi

    echo
    echo "Building librealsense with ${BUILD_JOBS} jobs..."

    if ! make -j"${BUILD_JOBS}" 2>&1 | tee "${BUILD_LOG}"; then
        return 20
    fi

    return 0
}

BUILD_OK=false
MAX_ATTEMPTS=5

for attempt in $(seq 1 "${MAX_ATTEMPTS}"); do

    echo
    echo "============================================================"
    echo " Build attempt ${attempt}/${MAX_ATTEMPTS}"
    echo "============================================================"

    if configure_and_build; then
        BUILD_OK=true
        break
    fi

    COMBINED_LOG="${BUILD_ROOT}/combined_error.log"
    cat "${CMAKE_LOG}" "${BUILD_LOG}" > "${COMBINED_LOG}" 2>/dev/null || true

    FALLBACK_APPLIED=false

    if [ "${BUILD_WITH_CUDA}" = "ON" ] &&
       grep -qiE 'CUDA|nvcc|CMAKE_CUDA|cuda compiler|unsupported gpu architecture' "${COMBINED_LOG}"; then

        echo
        echo "[WARNING] CUDA-related build failure detected."
        echo "[WARNING] Retrying with BUILD_WITH_CUDA=OFF."

        BUILD_WITH_CUDA="OFF"
        CMAKE_CUDA_ARGS=()
        FALLBACK_APPLIED=true

    elif { [ "${BUILD_WITH_DDS}" = "ON" ] || [ "${BUILD_ROSBAG2}" = "ON" ]; } &&
         grep -qiE 'FastDDS|fastdds|FastCDR|fastcdr|FastRTPS|fastrtps|eProsima|DDS' "${COMBINED_LOG}"; then

        echo
        echo "[WARNING] DDS/FastDDS/FastCDR build failure detected."
        echo "[WARNING] Retrying with DDS and ROSBag2 disabled."

        BUILD_WITH_DDS="OFF"
        BUILD_ROSBAG2="OFF"
        FALLBACK_APPLIED=true

    elif [ "${CHECK_FOR_UPDATES}" = "ON" ] &&
         grep -qiE 'curl|libcurl|CURL' "${COMBINED_LOG}"; then

        echo
        echo "[WARNING] curl/update-check build failure detected."
        echo "[WARNING] Retrying with CHECK_FOR_UPDATES=OFF."

        CHECK_FOR_UPDATES="OFF"
        FALLBACK_APPLIED=true
    fi

    if [ "${FALLBACK_APPLIED}" = false ]; then
        echo
        echo "ERROR:"
        echo "Build failed for a reason that is not covered by an optional fallback."
        echo
        echo "The previous librealsense installation has NOT been removed."
        echo
        echo "See:"
        echo "  ${CMAKE_LOG}"
        echo "  ${BUILD_LOG}"
        exit 1
    fi
done

if [ "${BUILD_OK}" != true ]; then
    echo
    echo "ERROR:"
    echo "librealsense could not be built after ${MAX_ATTEMPTS} attempts."
    echo
    echo "The previous installation has NOT been removed."
    exit 1
fi

# ============================================================
# Validar configuração efetiva
# ============================================================

cd "${BUILD_DIR}"

echo
echo "Checking final CMake configuration..."

declare -A EXPECTED_CMAKE_OPTIONS=(
    [FORCE_RSUSB_BACKEND]=ON
    [CHECK_FOR_UPDATES]="${CHECK_FOR_UPDATES}"
    [BUILD_EXAMPLES]=ON
    [BUILD_GRAPHICAL_EXAMPLES]=ON
    [BUILD_GLSL_EXTENSIONS]=ON
    [BUILD_TOOLS]=ON
    [BUILD_ROSBAG2]="${BUILD_ROSBAG2}"
    [BUILD_RS2_ALL]=ON
    [BUILD_WITH_DDS]="${BUILD_WITH_DDS}"
    [BUILD_WITH_CUDA]="${BUILD_WITH_CUDA}"
)

for option in "${!EXPECTED_CMAKE_OPTIONS[@]}"; do

    expected="${EXPECTED_CMAKE_OPTIONS[$option]}"

    if grep -q "^${option}:BOOL=${expected}$" CMakeCache.txt; then
        echo "[OK] ${option}=${expected}"
    else
        echo
        echo "ERROR:"
        echo "${option} was expected to be ${expected}"
        echo "Actual cache entry:"
        grep "^${option}:" CMakeCache.txt || true
        echo
        echo "The previous librealsense installation has NOT been removed."
        exit 1
    fi
done

# Viewer é obrigatório neste perfil.
if [ ! -x "${BUILD_DIR}/Release/realsense-viewer" ] &&
   [ ! -x "${BUILD_DIR}/tools/realsense-viewer/realsense-viewer" ]; then

    # O caminho varia conforme a configuração do projeto.
    if ! find "${BUILD_DIR}" -type f -name realsense-viewer -perm -111 -print -quit |
         grep -q .; then

        echo
        echo "ERROR:"
        echo "realsense-viewer was not generated by the build."
        echo "The previous installation has NOT been removed."
        exit 1
    fi
fi

echo
echo "============================================================"
echo " New build completed successfully"
echo "============================================================"
echo " CUDA         : ${BUILD_WITH_CUDA}"
echo " DDS          : ${BUILD_WITH_DDS}"
echo " ROSBag2      : ${BUILD_ROSBAG2}"
echo " Updates      : ${CHECK_FOR_UPDATES}"
echo " Viewer       : ON"
echo " GLSL         : ON"
echo " Tools        : ON"
echo "============================================================"

# ============================================================
# SOMENTE AGORA remover a instalação anterior
# ============================================================

echo
echo "Preparing to replace previous librealsense installation..."

if [ -s "${PREVIOUS_MANIFEST}" ]; then

    echo
    echo "Removing previous source installation using preserved manifest..."

    while IFS= read -r installed_file; do

        [ -n "${installed_file}" ] || continue

        if [ -e "${installed_file}" ] || [ -L "${installed_file}" ]; then
            run_root rm -vf -- "${installed_file}"
        fi

    done < "${PREVIOUS_MANIFEST}"

    run_root ldconfig

else

    # Se existe uma instalação manual em /usr/local sem manifesto,
    # não sobrescrevemos cegamente.
    if [ "${EXISTING_MANUAL_PREFIX}" = "/usr/local" ]; then

        echo
        echo "ERROR:"
        echo "A manual librealsense installation exists in /usr/local,"
        echo "but no install_manifest.txt was available."
        echo
        echo "Detected version: ${EXISTING_MANUAL_VERSION}"
        echo
        echo "The NEW build succeeded, but installation was NOT performed."
        echo "Refusing to overwrite an unmanaged /usr/local installation."
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
    echo "The SDK will be installed in the container, but udev rules"
    echo "must also be installed on the HOST."
    echo
    echo "Required host rules:"
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
echo "Installing librealsense..."

run_root make install
run_root ldconfig

# ============================================================
# Validar instalação
# ============================================================

echo
echo "Validating librealsense installation..."

if ! command -v pkg-config >/dev/null 2>&1; then
    echo "ERROR: pkg-config not found."
    exit 1
fi

INSTALLED_VERSION="$(
    pkg-config --modversion realsense2
)"

echo
echo "Installed librealsense version:"
echo "  ${INSTALLED_VERSION}"

if [ "${INSTALLED_VERSION}" != "${LIBREALSENSE_VERSION}" ]; then
    echo
    echo "ERROR:"
    echo "Expected:  ${LIBREALSENSE_VERSION}"
    echo "Installed: ${INSTALLED_VERSION}"
    exit 1
fi

echo
echo "Installed librealsense libraries:"

if ! ldconfig -p | grep librealsense; then
    echo
    echo "ERROR:"
    echo "librealsense was not found in ldconfig."
    exit 1
fi

# ============================================================
# Validar tools
# ============================================================

echo
echo "Checking RealSense tools..."

TOOLS=(
    rs-enumerate-devices
    rs-fw-update
    rs-fw-logger
    rs-terminal
    rs-record
    rs-convert
    realsense-viewer
)

for tool in "${TOOLS[@]}"; do

    if command -v "${tool}" >/dev/null 2>&1; then
        echo "[OK] ${tool}: $(command -v "${tool}")"
    else
        echo "[WARNING] ${tool} was not found."
    fi
done

if ! command -v rs-enumerate-devices >/dev/null 2>&1; then
    echo
    echo "ERROR:"
    echo "rs-enumerate-devices was not installed."
    exit 1
fi

if ! command -v realsense-viewer >/dev/null 2>&1; then
    echo
    echo "ERROR:"
    echo "realsense-viewer was not installed."
    exit 1
fi

# A nova instalação já possui seu próprio install_manifest.txt.
rm -f "${PREVIOUS_MANIFEST}"

# ============================================================
# Verificar versão do wrapper ROS
# ============================================================

SCRIPT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")" &&
    pwd
)"

REALSENSE_ROS_ROOT="$(
    cd "${SCRIPT_DIR}/.." 2>/dev/null &&
    pwd || true
)"

PACKAGE_XML="${REALSENSE_ROS_ROOT}/realsense2_camera/package.xml"

if [ -f "${PACKAGE_XML}" ]; then

    WRAPPER_VERSION="$(
        sed -n \
            's:.*<version>\([^<]*\)</version>.*:\1:p' \
            "${PACKAGE_XML}" |
        head -n1
    )"

    echo
    echo "Detected realsense-ros version:"
    echo "  ${WRAPPER_VERSION}"

    if [ "${WRAPPER_VERSION}" != "${REALSENSE_ROS_VERSION}" ]; then
        echo
        echo "WARNING:"
        echo "Expected wrapper: ${REALSENSE_ROS_VERSION}"
        echo "Repository reports: ${WRAPPER_VERSION}"
    fi
fi

# ============================================================
# Final
# ============================================================

echo
echo -e "\e[92m"
echo "============================================================"
echo " RealSense installation completed successfully"
echo "============================================================"
echo " librealsense : ${INSTALLED_VERSION}"
echo " realsense-ros: ${REALSENSE_ROS_VERSION}"
echo " backend      : RSUSB"
echo " CUDA         : ${BUILD_WITH_CUDA}"
echo " DDS          : ${BUILD_WITH_DDS}"
echo " ROSBag2      : ${BUILD_ROSBAG2}"
echo " GLSL         : ON"
echo " Viewer       : ON"
echo " Tools        : ON"
echo " Examples     : ON"
echo " RS2_ALL      : ON"
echo " Updates      : ${CHECK_FOR_UPDATES}"
echo " firmware alvo: ${EXPECTED_FIRMWARE}"
echo "============================================================"
echo -e "\e[0m"

echo
echo "Reconnect the D435i."
echo
echo "Check device:"
echo
echo "  rs-enumerate-devices | grep -E \\"
echo "    'Name|Serial Number|Firmware Version|USB Type Descriptor'"
echo
echo "Open viewer:"
echo
echo "  realsense-viewer"
echo
echo "Check SDK:"
echo
echo "  pkg-config --modversion realsense2"
echo
echo "IMPORTANT:"
echo "Rebuild realsense-ros so it links against librealsense ${LIBREALSENSE_VERSION}."
echo