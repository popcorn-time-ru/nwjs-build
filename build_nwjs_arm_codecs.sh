#!/usr/bin/env bash

set -e

FIRST_RUN=1
BUILD_ARM=0
BUILD_SDK=1
BUILD_NACL=1
NWJS_BRANCH="nw55"

export LC_ALL=C.UTF-8


# Steps and arguments taken from:
#   http://buildbot-master.nwjs.io:8010/builders/nw44_sdk_linux64/builds/27
#     Click on a step's logs to see the environment variables/commands
#   https://github.com/LeonardLaszlo/nw.js-armv7-binaries/blob/master/building-script.sh
#   https://github.com/LeonardLaszlo/nw.js-armv7-binaries/blob/master/docs/build-nwjs-v0.28.x.md

# For defines/args references, see:
#   https://web.archive.org/web/20160818205525/https://chromium.googlesource.com/chromium/src/+/master/tools/gn/docs/cookbook.md
#   https://github.com/nwjs/chromium.src/blob/22851eb48fe67f4419acc9b61b45ce61aad2c90b/native_client_sdk/src/build_tools/buildbot_run.py#L26

export GYP_CHROMIUM_NO_ACTION=0
export GYP_DEFINES="building_nw=1 buildtype=Official clang=1 OS=linux"
export GN_ARGS="is_debug=false target_os=\"linux\" is_component_ffmpeg=true is_component_build=false symbol_level=1 ffmpeg_branding=\"Chrome\""

if (( BUILD_SDK )); then
    export GYP_DEFINES="${GYP_DEFINES} nwjs_sdk=1"
    export GN_ARGS="${GN_ARGS} nwjs_sdk=true"
else
    export GYP_DEFINES="${GYP_DEFINES} nwjs_sdk=0"
    export GN_ARGS="${GN_ARGS} nwjs_sdk=false"
fi

if (( BUILD_NACL )); then
    export GYP_DEFINES="${GYP_DEFINES} disable_nacl=0"
    export GN_ARGS="${GN_ARGS} enable_nacl=true"
else
    export GYP_DEFINES="${GYP_DEFINES} disable_nacl=1"
    export GN_ARGS="${GN_ARGS} enable_nacl=false"
fi

if (( BUILD_ARM )); then
    export GYP_DEFINES="${GYP_DEFINES} target_arch=arm target_cpu=arm arm_float_abi=hard"
    export GN_ARGS="${GN_ARGS} target_cpu=\"arm\" arm_float_abi=\"hard\""
else
    export GYP_DEFINES="${GYP_DEFINES} target_arch=x64"
    export GN_ARGS="${GN_ARGS} target_cpu=\"x64\""
fi

export GN_ARGS="${GN_ARGS} proprietary_codecs=true enable_platform_hevc=true enable_mse_mpeg2ts_stream_parser=true enable_platform_mpeg_h_audio=true enable_platform_ac3_eac3_audio=true chrome_pgo_phase=0"


################################ Initial Setup #################################

# Pre-requisites
if (( FIRST_RUN )); then
    sudo apt update
    sudo apt install -y git python2 file lsb-release
fi


# Cloning Chromium depot tools.
if [[ ! -d "depot_tools" ]]; then
    git clone "https://chromium.googlesource.com/chromium/tools/depot_tools.git"
fi
export PATH="${PATH}:${PWD}/depot_tools"


# Configuring gclient for NW.js.
cat <<CONFIG > ".gclient"
solutions = [
  { "name"        : 'src',
    "url"         : 'https://github.com/nwjs/chromium.src.git@origin/${NWJS_BRANCH}',
    "deps_file"   : 'DEPS',
    "managed"     : True,
    "custom_deps" : {
        "src/third_party/WebKit/LayoutTests": None,
        "src/chrome_frame/tools/test/reference_build/chrome": None,
        "src/chrome_frame/tools/test/reference_build/chrome_win": None,
        "src/chrome/tools/test/reference_build/chrome": None,
        "src/chrome/tools/test/reference_build/chrome_linux": None,
        "src/chrome/tools/test/reference_build/chrome_mac": None,
        "src/chrome/tools/test/reference_build/chrome_win": None,
    },
    "custom_vars": {},
  },
]
CONFIG


clone_or_fetch() {
    repo_url="${1}"
    repo_path="${2}"
    repo_branch="${3}"
    if [[ -d "${repo_path}" ]]; then
        (
            cd "${repo_path}" &&
            git fetch --tags "${repo_url}" "${repo_branch}" &&
            git reset --hard origin/"${repo_branch}"
        )
    else
        git clone --depth 1 --branch "${repo_branch}" "${repo_url}" "${repo_path}"
    fi
}

# Cloning sources to required paths.
clone_or_fetch "https://github.com/nwjs/nw.js" "src/content/nw"          "${NWJS_BRANCH}"
clone_or_fetch "https://github.com/nwjs/node"  "src/third_party/node-nw" "${NWJS_BRANCH}"
clone_or_fetch "https://github.com/nwjs/v8"    "src/v8"                  "${NWJS_BRANCH}"


# Clone Chromium (and go grab a big cup of coffee).
sync_args=(--with_branch_heads --reset --verbose)
if (( FIRST_RUN )); then
    sync_args+=(--nohooks)
fi
gclient sync "${sync_args[@]}"


cd src


# Installing build dependencies (and go grab a small cup of coffee).
build_deps_args=(--no-prompt --no-backwards-compatible)
if (( BUILD_ARM )); then
    # Although allegedly enabled by default, we should be explicit just in case.
    build_deps_args+=(--arm)
fi
if (( FIRST_RUN )); then
    sudo ./build/install-build-deps.sh "${build_deps_args[@]}"
fi

if (( BUILD_ARM )); then
    # Installing required sysroot files for ARM target architecture.
    # WARNING: don't sudo this command or you'll be in for a bad time.
    #   It will cause the sysroot to extract with a different owner/group ID
    #   that non-root users won't be able to read.  This silently causes
    #   part of the `gn gen` step to fail and you will waste hours
    #   trying to track down the reason.
    build/linux/sysroot_scripts/install-sysroot.py --arch=arm
fi

# Pull all other required dependencies.
if (( FIRST_RUN )); then
    gclient runhooks
fi



################################### Patches ####################################

cd third_party/ffmpeg

# Enable nonfree codecs and ignore licence check
patch -p1 < $(dirname "$0")/ffmpeg.patch

############################ Recompile configs #################################

python3 ./chromium/scripts/build_ffmpeg.py linux x64 --config-only
./chromium/scripts/copy_config.sh 
python3 ./chromium/scripts/generate_gn.py

cd ../..

############################ Build File Generation #############################

# Patching third_party/node-nw/common.gypi is no longer required!  Thank you Roger!
#   See: https://github.com/nwjs/node/pull/38

# Modifying package_binaries.py is no longer required!  Thank you Roger!
#   See: https://github.com/nwjs/nw.js/pull/7382

# Generating build files for NW.js
gn gen "out/nw" --args="${GN_ARGS}"

# Generating build files for node.
./build/gyp_chromium -I third_party/node-nw/common.gypi third_party/node-nw/node.gyp



############################# Project Compilation ##############################

# Build the beast (and go grab a lunch, another coffee, and a snack).
# On a clean build, this step takes around 5 hours.
ninja -C out/nw nwjs

# This outputs a few warnings.  That's probably ok?
ninja -C out/Release node

# Copying GYP built node to GN output directory.
ninja -C out/nw copy_node

# `content/nw/BUILD.gn` uses the `build/linux/dump_app_syms.py` tool to strip binaries.
# This is an issue, as the `dump_app_syms.py` script calls the host's `strip` executable
# which is unlikely to support stripping the ARM architecture binaries.
# As a workaround, we create a wrapper `strip` script that uses `llvm-objcopy`
# from Chromium's build toolchain which supports almost every architecture.
if (( BUILD_ARM )); then
    temp_dir=$(mktemp -d)
    OLD_PATH="${PATH}"
    export PATH="${temp_dir}:${PATH}"

    # Typically under `third_party/llvm-build/Release+Asserts/bin`, but search for it just in case.
    objcopy=$(find . -type f -name "llvm-objcopy" | head -1 | xargs -n 1 realpath)
    cat > "${temp_dir}/strip" <<STRIP_SCRIPT 
#!/bin/sh
"${objcopy}" --strip-unneeded "\$@"
STRIP_SCRIPT
    chmod +x "${temp_dir}/strip"
fi

# Extracting symbols and stripping binaries.
ninja -C out/nw dump

if (( BUILD_ARM )); then
    export PATH="${OLD_PATH}"
    rm -rf "${temp_dir}"
fi

# Packaging results for distribution.
# Results end up in out/nw/dist.
ninja -C out/nw dist
