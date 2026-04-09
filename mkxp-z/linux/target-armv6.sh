#!/usr/bin/env bash

# Deps instructions:
# sudo dpkg --add-architecture armhf
# (Target versions of xorg-dev; removes native versions of: libxfont-dev xorg-dev xserver-xorg-dev) sudo apt install libfontenc-dev:armhf libfs-dev:armhf libice-dev:armhf libsm-dev:armhf libx11-dev:armhf libxau-dev:armhf libxaw7-dev:armhf libxcomposite-dev:armhf libxcursor-dev:armhf libxdamage-dev:armhf libxdmcp-dev:armhf libxext-dev:armhf libxfixes-dev:armhf libxfont-dev:armhf libxft-dev:armhf libxi-dev:armhf libxinerama-dev:armhf libxkbfile-dev:armhf libxmu-dev:armhf libxmuu-dev:armhf libxpm-dev:armhf libxrandr-dev:armhf libxrender-dev:armhf libxres-dev:armhf libxss-dev:armhf libxt-dev:armhf libxtst-dev:armhf libxv-dev:armhf libxvmc-dev:armhf libxxf86dga-dev:armhf libxxf86vm-dev:armhf x11proto-dev:armhf xserver-xorg-dev:armhf xtrans-dev:armhf
# sudo apt install gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf zlib1g-dev:armhf libbz2-dev:armhf libgl1-mesa-dev:armhf libasound2-dev:armhf libpulse-dev:armhf

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

export ARCH=armv6
export ARCH_OPENSSL=linux-armv4
# -march flags from:
# https://raspberrypi.stackexchange.com/questions/2046/which-cpu-flags-are-suitable-for-gcc-on-raspberry-pi
# https://stackoverflow.com/questions/35132319/build-for-armv6-with-gnueabihf
# Disable Thumb since Raspbian doesn't use it and it produces a compiler error:
# https://thinkingeek.com/2014/12/20/arm-assembler-raspberry-pi-chapter-22/
export ARCH_CFLAGS="-march=armv6zk+vfpv2 -marm"
export ARCH_CONFIGURE=arm-linux-gnueabihf
export CC="$ARCH_CONFIGURE-gcc"
export ARCH_CMAKE_TOOLCHAIN=toolchain-arm32.cmake
export ARCH_MESON_TOOLCHAIN=meson-armv6.txt
