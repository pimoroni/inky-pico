export TERM=${TERM:="xterm-256color"}

MICROPYTHON_FLAVOUR="peterharperuk"
MICROPYTHON_VERSION="pico2_w_changes"

PIMORONI_PICO_FLAVOUR="pimoroni"
PIMORONI_PICO_VERSION="feature/inky-pico2_w"

PY_DECL_VERSION="v0.0.3"
DIR2UF2_VERSION="v0.0.9"

if [ -z ${CI_PROJECT_ROOT+x} ]; then
    SCRIPT_PATH="$(dirname $0)"
    CI_PROJECT_ROOT=$(realpath "$SCRIPT_PATH/..")
fi

if [ -z ${CI_BUILD_ROOT+x} ]; then
    CI_BUILD_ROOT=$(pwd)
fi


function log_success {
	echo -e "$(tput setaf 2)$1$(tput sgr0)"
}

function log_inform {
	echo -e "$(tput setaf 6)$1$(tput sgr0)"
}

function log_warning {
	echo -e "$(tput setaf 1)$1$(tput sgr0)"
}

function ci_pimoroni_pico_clone {
    log_inform "Using Pimoroni Pico $PIMORONI_PICO_FLAVOUR/$PIMORONI_PICO_VERSION"
    git clone https://github.com/$PIMORONI_PICO_FLAVOUR/pimoroni-pico "$CI_BUILD_ROOT/pimoroni-pico"
    cd "$CI_BUILD_ROOT/pimoroni-pico" || return 1
    git checkout $PIMORONI_PICO_VERSION
    git submodule update --init
    cd "$CI_BUILD_ROOT"
}

function ci_micropython_clone {
    log_inform "Using MicroPython $MICROPYTHON_FLAVOUR/$MICROPYTHON_VERSION"
    git clone https://github.com/$MICROPYTHON_FLAVOUR/micropython "$CI_BUILD_ROOT/micropython"
    cd "$CI_BUILD_ROOT/micropython" || return 1
    git checkout $MICROPYTHON_VERSION
    git submodule update --init lib/pico-sdk
    git submodule update --init lib/cyw43-driver
    git submodule update --init lib/lwip
    git submodule update --init lib/mbedtls
    git submodule update --init lib/micropython-lib
    git submodule update --init lib/tinyusb
    git submodule update --init lib/btstack
    cd "$CI_BUILD_ROOT"
}

function ci_tools_clone {
    mkdir -p "$CI_BUILD_ROOT/tools"
    git clone https://github.com/gadgetoid/py_decl -b "$PY_DECL_VERSION" "$CI_BUILD_ROOT/tools/py_decl"
    git clone https://github.com/gadgetoid/dir2uf2 -b "$DIR2UF2_VERSION" "$CI_BUILD_ROOT/tools/dir2uf2"
}

function ci_micropython_build_mpy_cross {
    cd "$CI_BUILD_ROOT/micropython/mpy-cross" || return 1
    ccache --zero-stats || true
    CROSS_COMPILE="ccache " make
    ccache --show-stats || true
    cd "$CI_BUILD_ROOT"
}

function ci_apt_install_build_deps {
    sudo apt update && sudo apt install ccache python3-virtualenvwrapper virtualenvwrapper
}

function ci_prepare_all {
    ci_tools_clone
    ci_micropython_clone
    ci_pimoroni_pico_clone
    ci_micropython_build_mpy_cross
}

function ci_debug {
    log_inform "Project root: $CI_PROJECT_ROOT"
    log_inform "Build root: $CI_BUILD_ROOT"
}

function micropython_version {
    BOARD=$1
    echo "MICROPY_GIT_TAG=$MICROPYTHON_VERSION, $BOARD $TAG_OR_SHA" >> $GITHUB_ENV
    echo "MICROPY_GIT_HASH=$MICROPYTHON_VERSION-$TAG_OR_SHA" >> $GITHUB_ENV
}

function ci_cmake_configure {
    BOARD=$1
    MICROPY_BOARD_DIR=$CI_PROJECT_ROOT/boards/$BOARD
    if [ ! -f "$MICROPY_BOARD_DIR/usermodules.cmake" ]; then
        log_warning "Invalid board: $MICROPY_BOARD_DIR"
        return 1
    fi
    BUILD_DIR="$CI_BUILD_ROOT/build-$BOARD"
    cmake -S $CI_BUILD_ROOT/micropython/ports/rp2 -B "$BUILD_DIR" \
    -DPICOTOOL_FORCE_FETCH_FROM_GIT=1 \
    -DPICO_BUILD_DOCS=0 \
    -DPICO_NO_COPRO_DIS=1 \
    -DPIMORONI_PICO_PATH="$CI_BUILD_ROOT/pimoroni-pico" \
    -DUSER_C_MODULES="$MICROPY_BOARD_DIR/usermodules.cmake" \
    -DMICROPY_BOARD_DIR="$MICROPY_BOARD_DIR" \
    -DMICROPY_BOARD="$BOARD" \
    -DCMAKE_C_COMPILER_LAUNCHER=ccache \
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
}

function ci_cmake_build {
    BOARD=$1
    MICROPY_BOARD_DIR=$CI_PROJECT_ROOT/boards/$BOARD
    EXAMPLES_DIR=$CI_PROJECT_ROOT/examples/inkylauncher/
    TOOLS_DIR=$CI_BUILD_ROOT/tools
    BUILD_DIR="$CI_BUILD_ROOT/build-$BOARD"
    ccache --zero-stats || true
    cmake --build $BUILD_DIR -j 2
    ccache --show-stats || true
    if [ -d "$TOOLS_DIR/py_decl" ]; then
        log_inform "Tools found, verifying .uf2 with py_decl..."
        python3 "$TOOLS_DIR/py_decl/py_decl.py" --to-json --verify "$BUILD_DIR/firmware.uf2"
    fi
    log_inform "Copying .uf2 to $(pwd)/$BOARD.uf2"
    cp "$BUILD_DIR/firmware.uf2" $BOARD.uf2

    if [ -f "$MICROPY_BOARD_DIR/manifest.txt" ] && [ -d "$TOOLS_DIR/dir2uf2" ]; then
        log_inform "Creating $(pwd)/$BOARD-with-filesystem.uf2"
        python3 -m pip install littlefs-python==0.12.0
        $TOOLS_DIR/dir2uf2/dir2uf2 --fs-compact --sparse --append-to "$(pwd)/$BOARD.uf2" --manifest "$MICROPY_BOARD_DIR/manifest.txt" --filename with-filesystem.uf2 "$EXAMPLES_DIR"
    fi
}
