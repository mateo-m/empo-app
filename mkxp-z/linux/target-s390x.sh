#!/usr/bin/env bash

# Deps instructions:
# sudo dpkg --add-architecture s390x
# (Target versions of xorg-dev; removes native versions of: libxfont-dev xorg-dev xserver-xorg-dev) sudo apt install libfontenc-dev:s390x libfs-dev:s390x libice-dev:s390x libsm-dev:s390x libx11-dev:s390x libxau-dev:s390x libxaw7-dev:s390x libxcomposite-dev:s390x libxcursor-dev:s390x libxdamage-dev:s390x libxdmcp-dev:s390x libxext-dev:s390x libxfixes-dev:s390x libxfont-dev:s390x libxft-dev:s390x libxi-dev:s390x libxinerama-dev:s390x libxkbfile-dev:s390x libxmu-dev:s390x libxmuu-dev:s390x libxpm-dev:s390x libxrandr-dev:s390x libxrender-dev:s390x libxres-dev:s390x libxss-dev:s390x libxt-dev:s390x libxtst-dev:s390x libxv-dev:s390x libxvmc-dev:s390x libxxf86dga-dev:s390x libxxf86vm-dev:s390x x11proto-dev:s390x xserver-xorg-dev:s390x xtrans-dev:s390x
# sudo apt install gcc-s390x-linux-gnu g++-s390x-linux-gnu zlib1g-dev:s390x libbz2-dev:s390x libgl1-mesa-dev:s390x libasound2-dev:s390x libpulse-dev:s390x

# Build instructions
# cd linux
# source target-whatever.sh
# make
# source vars.sh
# cd ../
# meson setup --cross-file ./linux/$ARCH_MESON_TOOLCHAIN build
# cd build
# ninja
# meson configure --bindir=. --prefix=$PWD/local
# ninja install
# cp "$MKXPZ_PREFIX/lib/$("$ARCH_CONFIGURE-objdump" -p local/mkxp-z* | grep -i NEEDED | grep -Eo 'libruby.so.[0-9\.]+')" local/lib64/
# cp "/usr/lib/$ARCH_CONFIGURE/$("$ARCH_CONFIGURE-objdump" -p local/lib64/libruby.so* | grep -i NEEDED | grep -Eo 'libcrypt.so.[0-9\.]+')" local/lib64/

export ARCH=s390x
export ARCH_OPENSSL=linux64-s390x
export ARCH_CFLAGS=""
export ARCH_CONFIGURE=s390x-linux-gnu
export CC="$ARCH_CONFIGURE-gcc"
export ARCH_CMAKE_TOOLCHAIN=toolchain-s390x.cmake
export ARCH_MESON_TOOLCHAIN=meson-s390x.txt
