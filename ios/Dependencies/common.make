SYSROOT := $(shell xcrun --sdk $(SDK) --show-sdk-path)
SDK_VERSION := $(shell xcrun --sdk $(SDK) --show-sdk-version)
TARGETFLAGS := -isysroot $(SYSROOT) $(TARGET_FLAG) -arch $(ARCH)

# `ld -platform_version <platform> <min> <sdk>` — needed for ld -r
# linking on modern Apple toolchains. Platform name differs between
# device (`ios`) and simulator (`ios-simulator`); we infer from $(SDK).
ifeq ($(SDK),iphonesimulator)
LD_PLATFORM := ios-simulator
else
LD_PLATFORM := ios
endif
LD_PLATFORM_VERSION := -platform_version $(LD_PLATFORM) $(MINIMUM_REQUIRED) $(SDK_VERSION)
BUILD_PREFIX := ${PWD}/build-$(SDK)-$(ARCH)
LIBDIR := $(BUILD_PREFIX)/lib
INCLUDEDIR := $(BUILD_PREFIX)/include
DOWNLOADS := ${PWD}/downloads/$(HOST)
SOURCES := ${PWD}/sources
PATCHES := ${PWD}
ENGINE := ${PWD}/../../mkxp-z-apple-mobile
NPROC := $(shell sysctl -n hw.ncpu)
CFLAGS := -I$(INCLUDEDIR) -I$(INCLUDEDIR)/freetype2 $(TARGETFLAGS) -O3
CXXFLAGS := $(CFLAGS)
LDFLAGS := -L$(LIBDIR) $(TARGETFLAGS)
CC      := $(shell xcrun --sdk $(SDK) -f clang) -arch $(ARCH)
CXX     := $(shell xcrun --sdk $(SDK) -f clang++) -arch $(ARCH)
AR      := $(shell xcrun --sdk $(SDK) -f ar)
RANLIB  := $(shell xcrun --sdk $(SDK) -f ranlib)
PKG_CONFIG_LIBDIR := $(BUILD_PREFIX)/lib/pkgconfig
GIT := git
CLONE := $(GIT) clone -q
GITHUB := https://github.com

# Host build triple for cross-compilation (Apple system Ruby returns non-standard string)
RBUILD := aarch64-apple-darwin

CPPFLAGS := -isysroot $(SYSROOT) $(CFLAGS)

CONFIGURE_ENV := \
	PKG_CONFIG_LIBDIR=$(PKG_CONFIG_LIBDIR) \
	CC="$(CC)" CXX="$(CXX)" AR="$(AR)" RANLIB="$(RANLIB)" \
	CFLAGS="$(CFLAGS)" CXXFLAGS="$(CXXFLAGS)" CPPFLAGS="$(CPPFLAGS)" LDFLAGS="$(LDFLAGS)"

CONFIGURE_ARGS := \
	--prefix="$(BUILD_PREFIX)" \
	--host=$(HOST)

CMAKE_ARGS := \
	-DCMAKE_INSTALL_PREFIX="$(BUILD_PREFIX)" \
	-DCMAKE_PREFIX_PATH="$(BUILD_PREFIX)" \
	-DCMAKE_OSX_ARCHITECTURES=$(ARCH) \
	-DCMAKE_OSX_SYSROOT=$(SYSROOT) \
	-DCMAKE_C_FLAGS="$(CFLAGS)" \
	-DCMAKE_CXX_FLAGS="$(CXXFLAGS)" \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_SYSTEM_NAME=iOS \
	-DCMAKE_OSX_DEPLOYMENT_TARGET=$(MINIMUM_REQUIRED) \
	-DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
	-DCMAKE_FIND_ROOT_PATH="$(BUILD_PREFIX)" \
	-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH \
	-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH \
	-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH

# Ruby: static only for iOS, no JIT, no fiddle, no shared
RUBY_CONFIGURE_ARGS := \
	--disable-shared \
	--enable-install-static-library \
	--with-static-linked-ext \
	--with-out-ext=fiddle,gdbm,win32ole,win32,pty,syslog,readline,bigdecimal \
	--disable-rubygems \
	--disable-install-doc \
	--disable-jit-support \
	--build=$(RBUILD) \
	${EXTRA_RUBY_CONFIG_ARGS}

CONFIGURE := $(CONFIGURE_ENV) ./configure $(CONFIGURE_ARGS)
AUTOGEN   := $(CONFIGURE_ENV) ./autogen.sh $(CONFIGURE_ARGS)
CMAKE     := $(CONFIGURE_ENV) cmake .. $(CMAKE_ARGS)

default:

# Theora
libtheora: init_dirs libvorbis libogg $(LIBDIR)/libtheora.a

$(LIBDIR)/libtheora.a: $(LIBDIR)/libogg.a $(DOWNLOADS)/theora/Makefile
	cd $(DOWNLOADS)/theora; \
	make -j$(NPROC); make install

$(DOWNLOADS)/theora/Makefile: $(DOWNLOADS)/theora/configure
	cd $(DOWNLOADS)/theora; \
	$(CONFIGURE) --with-ogg=$(BUILD_PREFIX) --enable-shared=false --enable-static=true --disable-examples

$(DOWNLOADS)/theora/configure: $(DOWNLOADS)/theora/autogen.sh
	cd $(DOWNLOADS)/theora; \
	./autogen.sh

$(DOWNLOADS)/theora/autogen.sh:
	$(CLONE) $(GITHUB)/xiph/theora $(DOWNLOADS)/theora

# Vorbis
libvorbis: init_dirs libogg $(LIBDIR)/libvorbis.a

$(LIBDIR)/libvorbis.a: $(LIBDIR)/libogg.a $(DOWNLOADS)/vorbis/cmakebuild/Makefile
	cd $(DOWNLOADS)/vorbis/cmakebuild; \
	make -j$(NPROC); make install

$(DOWNLOADS)/vorbis/cmakebuild/Makefile: $(DOWNLOADS)/vorbis/CMakeLists.txt
	cd $(DOWNLOADS)/vorbis; \
	mkdir -p cmakebuild; cd cmakebuild; \
	$(CMAKE) -DBUILD_SHARED_LIBS=no

$(DOWNLOADS)/vorbis/CMakeLists.txt:
	$(CLONE) $(GITHUB)/xiph/vorbis -b v1.3.7 $(DOWNLOADS)/vorbis


# Ogg
libogg: init_dirs $(LIBDIR)/libogg.a

$(LIBDIR)/libogg.a: $(DOWNLOADS)/ogg/Makefile
	cd $(DOWNLOADS)/ogg; \
	make -j$(NPROC); make install

$(DOWNLOADS)/ogg/Makefile: $(DOWNLOADS)/ogg/configure
	cd $(DOWNLOADS)/ogg; \
	$(CONFIGURE) --enable-static=true --enable-shared=false

$(DOWNLOADS)/ogg/configure: $(DOWNLOADS)/ogg/autogen.sh
	cd $(DOWNLOADS)/ogg; ./autogen.sh

$(DOWNLOADS)/ogg/autogen.sh:
	$(CLONE) $(GITHUB)/xiph/ogg -b v1.3.6 $(DOWNLOADS)/ogg

# uchardet
uchardet: init_dirs $(LIBDIR)/libuchardet.a

$(LIBDIR)/libuchardet.a: $(DOWNLOADS)/uchardet/cmakebuild/Makefile
	cd $(DOWNLOADS)/uchardet/cmakebuild; \
	make -j$(NPROC); make install

$(DOWNLOADS)/uchardet/cmakebuild/Makefile: $(DOWNLOADS)/uchardet/CMakeLists.txt
	cd $(DOWNLOADS)/uchardet; \
	mkdir -p cmakebuild; cd cmakebuild; \
	$(CMAKE) -DBUILD_SHARED_LIBS=no -DBUILD_BINARY=OFF

$(DOWNLOADS)/uchardet/CMakeLists.txt:
	$(CLONE) https://gitlab.freedesktop.org/uchardet/uchardet -b v0.0.8 $(DOWNLOADS)/uchardet


# Pixman
pixman: init_dirs libpng $(LIBDIR)/libpixman-1.a

$(LIBDIR)/libpixman-1.a: $(DOWNLOADS)/pixman/Makefile
	cd $(DOWNLOADS)/pixman
	make -C $(DOWNLOADS)/pixman -j$(NPROC)
	make -C $(DOWNLOADS)/pixman install

$(DOWNLOADS)/pixman/Makefile: $(DOWNLOADS)/pixman/autogen.sh
	cd $(DOWNLOADS)/pixman; \
	$(AUTOGEN) --enable-static=yes --enable-shared=no \
	--disable-arm-a64-neon

$(DOWNLOADS)/pixman/autogen.sh:
	$(CLONE) https://gitlab.freedesktop.org/pixman/pixman -b pixman-0.42.2 $(DOWNLOADS)/pixman


# PhysFS
physfs: init_dirs $(LIBDIR)/libphysfs.a

$(LIBDIR)/libphysfs.a: $(DOWNLOADS)/physfs/cmakebuild/Makefile
	cd $(DOWNLOADS)/physfs/cmakebuild; \
	make -j$(NPROC); make install

$(DOWNLOADS)/physfs/cmakebuild/Makefile: $(DOWNLOADS)/physfs/CMakeLists.txt
	cd $(DOWNLOADS)/physfs; \
	mkdir -p cmakebuild; cd cmakebuild; \
	$(CMAKE) -DPHYSFS_BUILD_STATIC=true -DPHYSFS_BUILD_SHARED=false -DPHYSFS_BUILD_TEST=false

$(DOWNLOADS)/physfs/CMakeLists.txt:
	$(CLONE) $(GITHUB)/icculus/physfs -b release-3.2.0 $(DOWNLOADS)/physfs

# libpng
libpng: init_dirs $(LIBDIR)/libpng.a

$(LIBDIR)/libpng.a: $(DOWNLOADS)/libpng/Makefile
	cd $(DOWNLOADS)/libpng; \
	make -j$(NPROC); make install

$(DOWNLOADS)/libpng/Makefile: $(DOWNLOADS)/libpng/configure
	cd $(DOWNLOADS)/libpng; \
	$(CONFIGURE) \
	--enable-shared=no --enable-static=yes

$(DOWNLOADS)/libpng/configure:
	$(CLONE) $(GITHUB)/pnggroup/libpng -b v1.6.50 $(DOWNLOADS)/libpng

# SDL2 (submodule: sources/sdl2)
sdl2: init_dirs $(LIBDIR)/libSDL2.a

$(LIBDIR)/libSDL2.a: $(SOURCES)/sdl2/cmakebuild/Makefile
	cd $(SOURCES)/sdl2/cmakebuild; \
	make -j$(NPROC); make install

$(SOURCES)/sdl2/cmakebuild/Makefile: $(SOURCES)/sdl2/CMakeLists.txt
	cd $(SOURCES)/sdl2; \
	mkdir -p cmakebuild; cd cmakebuild; \
	$(CMAKE) -DBUILD_SHARED_LIBS=no \
	-DSDL_OPENGL=OFF \
	-DSDL_OPENGLES=ON \
	-DSDL_METAL=ON \
	-DSDL_RENDER_METAL=ON

# SDL_image (submodule: sources/sdl2_image)
sdl2image: init_dirs sdl2 $(LIBDIR)/libSDL2_image.a

$(LIBDIR)/libSDL2_image.a: $(SOURCES)/sdl2_image/cmakebuild/Makefile
	cd $(SOURCES)/sdl2_image/cmakebuild; \
	make -j$(NPROC); make install

$(SOURCES)/sdl2_image/cmakebuild/Makefile: $(SOURCES)/sdl2_image/CMakeLists.txt
	cd $(SOURCES)/sdl2_image; mkdir -p cmakebuild; cd cmakebuild; \
	$(CMAKE) \
	-DBUILD_SHARED_LIBS=no \
	-DSDL2IMAGE_JPG_SAVE=yes \
	-DSDL2IMAGE_PNG_SAVE=yes \
	-DSDL2IMAGE_PNG_SHARED=no \
	-DSDL2IMAGE_JPG_SHARED=no \
	-DSDL2IMAGE_JXL=no \
	-DSDL2IMAGE_BACKEND_IMAGEIO=no \
	-DSDL2IMAGE_VENDORED=yes


# SDL_sound (submodule: sources/sdl_sound)
sdlsound: init_dirs sdl2 libogg libvorbis $(LIBDIR)/libSDL2_sound.a

$(LIBDIR)/libSDL2_sound.a: $(SOURCES)/sdl_sound/cmakebuild/Makefile
	cd $(SOURCES)/sdl_sound/cmakebuild; \
	make -j$(NPROC); make install

$(SOURCES)/sdl_sound/cmakebuild/Makefile: $(SOURCES)/sdl_sound/CMakeLists.txt
	cd $(SOURCES)/sdl_sound; mkdir -p cmakebuild; cd cmakebuild; \
	$(CMAKE) \
	-DSDLSOUND_BUILD_SHARED=false \
	-DSDLSOUND_BUILD_TEST=false \
	-DSDLSOUND_DECODER_COREAUDIO=false


# SDL2_ttf (submodule: sources/sdl2_ttf)
sdl2ttf: init_dirs sdl2 freetype $(LIBDIR)/libSDL2_ttf.a

$(LIBDIR)/libSDL2_ttf.a: $(SOURCES)/sdl2_ttf/Makefile
	cd $(SOURCES)/sdl2_ttf; \
	make -j$(NPROC) lib; make install-libLTLIBRARIES install-libSDL2_ttfincludeHEADERS install-pkgconfigDATA

$(SOURCES)/sdl2_ttf/Makefile: $(SOURCES)/sdl2_ttf/configure
	cd $(SOURCES)/sdl2_ttf; \
	$(CONFIGURE) --enable-static=true --enable-shared=false

$(SOURCES)/sdl2_ttf/configure: $(SOURCES)/sdl2_ttf/autogen.sh
	cd $(SOURCES)/sdl2_ttf; ./autogen.sh

# OpenAL-Soft (submodule: sources/openal-soft)
#
# Replaces Apple's deprecated `-framework OpenAL` (frozen at the
# circa-2005 fork point, known buffer-management quirks on iOS that
# manifest as the Pokemon Infinite Fusion BGM-loop bug). OpenAL-Soft
# is the de-facto reference OpenAL 1.1 implementation, owns its
# own mixer ring (so `alSourceStop` actually drops samples instead
# of letting CoreAudio drain them), and is what JoiPlay ships on
# Android without exhibiting the loop.
#
# Static-lib build: every other dep here ships static, App Store
# accepts it, dyld doesn't pay an extra load. CoreAudio backend
# is the only one we need on iOS; everything else is forced off
# so the lib stays small. ALSOFT_REQUIRE_COREAUDIO=ON makes the
# CMake configure fail loudly if the backend isn't detected,
# rather than silently producing a no-output lib.
openal: init_dirs $(LIBDIR)/libopenal.a

$(LIBDIR)/libopenal.a: $(SOURCES)/openal-soft/cmakebuild/Makefile
	cd $(SOURCES)/openal-soft/cmakebuild; \
	make -j$(NPROC); make install

$(SOURCES)/openal-soft/cmakebuild/Makefile: $(SOURCES)/openal-soft/CMakeLists.txt
	cd $(SOURCES)/openal-soft; \
	mkdir -p cmakebuild; cd cmakebuild; \
	$(CMAKE) \
	-DLIBTYPE=STATIC \
	-DALSOFT_UTILS=OFF \
	-DALSOFT_EXAMPLES=OFF \
	-DALSOFT_TESTS=OFF \
	-DALSOFT_INSTALL_EXAMPLES=OFF \
	-DALSOFT_INSTALL_UTILS=OFF \
	-DALSOFT_INSTALL_AMBDEC_PRESETS=OFF \
	-DALSOFT_INSTALL_HRTF_DATA=OFF \
	-DALSOFT_BACKEND_COREAUDIO=ON \
	-DALSOFT_REQUIRE_COREAUDIO=ON \
	-DALSOFT_BACKEND_PIPEWIRE=OFF \
	-DALSOFT_BACKEND_PULSEAUDIO=OFF \
	-DALSOFT_BACKEND_ALSA=OFF \
	-DALSOFT_BACKEND_OSS=OFF \
	-DALSOFT_BACKEND_SOLARIS=OFF \
	-DALSOFT_BACKEND_SNDIO=OFF \
	-DALSOFT_BACKEND_PORTAUDIO=OFF \
	-DALSOFT_BACKEND_JACK=OFF \
	-DALSOFT_BACKEND_OPENSL=OFF \
	-DALSOFT_BACKEND_WAVE=OFF


# Freetype (submodule: sources/freetype)
freetype: init_dirs $(LIBDIR)/libfreetype.a

$(LIBDIR)/libfreetype.a: $(SOURCES)/freetype/builds/unix/unix-def.mk
	cd $(SOURCES)/freetype; \
	make -j$(NPROC); make install

$(SOURCES)/freetype/builds/unix/unix-def.mk: $(SOURCES)/freetype/builds/unix/configure
	cd $(SOURCES)/freetype; \
	$(CONFIGURE) --enable-static=true --enable-shared=false

$(SOURCES)/freetype/builds/unix/configure: $(SOURCES)/freetype/autogen.sh
	cd $(SOURCES)/freetype; ./autogen.sh

# Ruby 3.1 (submodule: sources/ruby)
ruby: init_dirs $(LIBDIR)/libruby.3.1-static.a $(LIBDIR)/libruby.3.1-ext.a

$(LIBDIR)/libruby.3.1-static.a: $(SOURCES)/ruby/Makefile
	cd $(SOURCES)/ruby; \
	$(CONFIGURE_ENV) make -j$(NPROC) libruby.3.1-static.a; \
	cp libruby.3.1-static.a $(LIBDIR)/; \
	mkdir -p $(INCLUDEDIR)/ruby31; \
	cp -R include/* $(INCLUDEDIR)/ruby31/; \
	cp .ext/include/*/ruby/config.h $(INCLUDEDIR)/ruby31/ruby/config.h 2>/dev/null || true
	@# Header isolation: 3.1 lives under $(INCLUDEDIR)/ruby31/,
	@# 3.0 under $(INCLUDEDIR)/ruby30/. Consumers (project.yml's
	@# HEADER_SEARCH_PATHS, the per-version mkxp{N}-merged make
	@# targets) must point at the right subdir for the version
	@# they want. No global $(INCLUDEDIR)/ruby.h fallback so 3.0
	@# builds don't accidentally see 3.1's headers and vice versa.

# Build Ruby 3.1 extensions (zlib, stringio, strscan, digest, etc.) plus
# encoding libs into libruby.3.1-ext.a. Mirrors the Ruby 1.8 pattern (see
# RUBY18_EXTS above). ext/extinit.o and enc/encinit.o replace the dmyext.o
# and dmyenc.o stubs that live in libruby.3.1-static.a.
$(LIBDIR)/libruby.3.1-ext.a: $(LIBDIR)/libruby.3.1-static.a
	cd $(SOURCES)/ruby; \
	$(CONFIGURE_ENV) make -j$(NPROC) exts encs || true
	@TMPDIR=$$(mktemp -d); \
	cd $$TMPDIR; \
	for a in $$(find $(SOURCES)/ruby/ext -name "*.a" -not -path "*/test/*") \
	         $(SOURCES)/ruby/enc/libenc.a $(SOURCES)/ruby/enc/libtrans.a; do \
		[ -f "$$a" ] || continue; \
		sub=$$(basename $$a .a); \
		mkdir -p "$$sub"; \
		(cd "$$sub" && $(AR) x "$$a"); \
	done; \
	cp $(SOURCES)/ruby/ext/extinit.o .; \
	cp $(SOURCES)/ruby/enc/encinit.o .; \
	$(AR) rcs $(LIBDIR)/libruby.3.1-ext.a extinit.o encinit.o */*.o; \
	$(RANLIB) $(LIBDIR)/libruby.3.1-ext.a; \
	rm -rf $$TMPDIR
	@# Strip dmyext.o and dmyenc.o from the core static lib so the real
	@# Init_ext and Init_enc in libruby.3.1-ext.a win at link time.
	$(AR) d $(LIBDIR)/libruby.3.1-static.a dmyext.o dmyenc.o || true
	$(RANLIB) $(LIBDIR)/libruby.3.1-static.a

$(SOURCES)/ruby/Makefile: $(SOURCES)/ruby/configure
	cd $(SOURCES)/ruby; \
	export $(CONFIGURE_ENV); \
	export CFLAGS="-std=gnu99 -DRUBY_FUNCTION_NAME_STRING=__func__ $$CFLAGS"; \
	export LDFLAGS="$$LDFLAGS"; \
	./configure $(CONFIGURE_ARGS) $(RUBY_CONFIGURE_ARGS) \
	--with-baseruby=/usr/bin/ruby \
	ac_cv_func_setpgrp_void=yes \
	ac_cv_func_fork=no \
	ac_cv_func_dup3=no \
	ac_cv_func_pipe2=no \
	ac_cv_func_getentropy=no \
	ac_cv_func_posix_spawn=no \
	ac_cv_func_posix_spawnp=no \
	ac_cv_func_fdatasync=no \
	ac_cv_func_preadv=no \
	ac_cv_func_pwritev=no \
	ac_cv_func_copy_file_range=no \
	ac_cv_func_close_range=no \
	cross_compiling=yes; \
	sed -i '' 's|^ASFLAGS.*=.*|ASFLAGS = $$(ARCH_FLAG) $$(INCFLAGS) $(TARGETFLAGS)|' Makefile

$(SOURCES)/ruby/configure: $(SOURCES)/ruby/configure.ac
	cd $(SOURCES)/ruby; \
	git checkout -- . 2>/dev/null; \
	git apply $(PATCHES)/ruby31/ios.patch; \
	for patch in $(ENGINE)/syntax-transform/3.1/[0-9]*.patch; do \
		echo "Applying syntax transform: $$(basename $$patch)"; \
		patch -p1 --fuzz=3 -i $$patch || exit 1; \
	done; \
	autoreconf -i

# Ruby 3.0 (submodule: sources/ruby30)
#
# Builds alongside the Ruby 3.1 install. JoiPlay's RPG Maker plugin
# ships exactly Ruby 1.8 + 1.9 + 3.0 (verified by inspecting the
# .apk's lib/arm64-v8a/ contents on 2026-04-27); mkxp-z's upstream
# pins to 3.0. Matching that validated set is the anchor.
#
# 3.0 SKIPS the syntax-transform patches. The point of multi-Ruby
# is running games on their actual native Ruby parser. Modern games
# written for Ruby 3.0+ don't need rewriting; vintage 1.8 / 1.9-
# grammar games run on libruby18 / libruby19 instead.
ruby30: init_dirs $(LIBDIR)/libruby.3.0-static.a $(LIBDIR)/libruby.3.0-ext.a

$(LIBDIR)/libruby.3.0-static.a: $(SOURCES)/ruby30/Makefile
	cd $(SOURCES)/ruby30; \
	$(CONFIGURE_ENV) make -j$(NPROC) libruby.3.0-static.a; \
	cp libruby.3.0-static.a $(LIBDIR)/; \
	mkdir -p $(INCLUDEDIR)/ruby30; \
	cp -R include/* $(INCLUDEDIR)/ruby30/; \
	cp .ext/include/*/ruby/config.h $(INCLUDEDIR)/ruby30/ruby/config.h 2>/dev/null || true

# Same ext-archive recipe as 3.1's, retargeted at the 3.0 source tree.
$(LIBDIR)/libruby.3.0-ext.a: $(LIBDIR)/libruby.3.0-static.a
	cd $(SOURCES)/ruby30; \
	$(CONFIGURE_ENV) make -j$(NPROC) exts encs || true
	@TMPDIR=$$(mktemp -d); \
	cd $$TMPDIR; \
	for a in $$(find $(SOURCES)/ruby30/ext -name "*.a" -not -path "*/test/*") \
	         $(SOURCES)/ruby30/enc/libenc.a $(SOURCES)/ruby30/enc/libtrans.a; do \
		[ -f "$$a" ] || continue; \
		sub=$$(basename $$a .a); \
		mkdir -p "$$sub"; \
		(cd "$$sub" && $(AR) x "$$a"); \
	done; \
	cp $(SOURCES)/ruby30/ext/extinit.o .; \
	cp $(SOURCES)/ruby30/enc/encinit.o .; \
	$(AR) rcs $(LIBDIR)/libruby.3.0-ext.a extinit.o encinit.o */*.o; \
	$(RANLIB) $(LIBDIR)/libruby.3.0-ext.a; \
	rm -rf $$TMPDIR
	@# Strip dmyext.o and dmyenc.o from the core static lib so the real
	@# Init_ext and Init_enc in libruby.3.0-ext.a win at link time.
	$(AR) d $(LIBDIR)/libruby.3.0-static.a dmyext.o dmyenc.o || true
	$(RANLIB) $(LIBDIR)/libruby.3.0-static.a

$(SOURCES)/ruby30/Makefile: $(SOURCES)/ruby30/configure
	cd $(SOURCES)/ruby30; \
	export $(CONFIGURE_ENV); \
	export CFLAGS="-std=gnu99 -DRUBY_FUNCTION_NAME_STRING=__func__ $$CFLAGS"; \
	export LDFLAGS="$$LDFLAGS"; \
	./configure $(CONFIGURE_ARGS) $(RUBY_CONFIGURE_ARGS) \
	ac_cv_func_setpgrp_void=yes \
	ac_cv_func_fork=no \
	ac_cv_func_dup3=no \
	ac_cv_func_pipe2=no \
	ac_cv_func_getentropy=no \
	ac_cv_func_posix_spawn=no \
	ac_cv_func_posix_spawnp=no \
	ac_cv_func_fdatasync=no \
	ac_cv_func_preadv=no \
	ac_cv_func_pwritev=no \
	ac_cv_func_copy_file_range=no \
	ac_cv_func_close_range=no \
	cross_compiling=yes; \
	sed -i '' 's|^ASFLAGS.*=.*|ASFLAGS = $$(ARCH_FLAG) $$(INCFLAGS) $(TARGETFLAGS)|' Makefile

$(SOURCES)/ruby30/configure: $(SOURCES)/ruby30/configure.ac
	cd $(SOURCES)/ruby30; \
	git checkout -- . 2>/dev/null; \
	git apply $(PATCHES)/ruby30/ios.patch; \
	autoreconf -i

# Per-Ruby-version mkxp-z binding compile + libruby merge.
#
# Phase D of MULTI_RUBY_PLAN.md (gitignored): ship multiple Ruby
# versions in one binary by compiling mkxp-z's binding code N times
# (once against each Ruby's headers), merging each compile +
# corresponding libruby into a single .o with `ld -r`, and demoting
# every Ruby-defined symbol (`_rb_*`, `_ruby_*`, etc.) to local via
# `-unexported_symbols_list`. Hidden Ruby symbols don't clash across
# versions; each merged .o exposes only its own `Init_mkxpNN`-style
# entry points to the host.
#
# This target builds the Ruby 3.0 slice. Sister targets (mkxp31-merged,
# mkxp19-merged, mkxp18-merged) follow once the binding compile shape
# is verified for 3.0.

# Where the binding-source-against-Ruby-3.0 .o files land. Versioned
# subdir under build-$(SDK)-$(ARCH) so the sister versions don't
# collide.
BINDING_OBJDIR_30 := $(BUILD_PREFIX)/binding30

# Mkxp-z's full -I list, mirroring project.yml's HEADER_SEARCH_PATHS.
# Includes both the engine source tree (so the binding can reach
# `audio/audio.h` etc. by short path) and the per-Ruby header dir
# placed AHEAD of the global $(INCLUDEDIR) to win against any 3.1
# header pollution.
MKXPZ_INCLUDES_30 := \
    -I$(INCLUDEDIR)/ruby30 \
    -I$(ENGINE) \
    -I$(ENGINE)/src \
    -I$(ENGINE)/src/audio \
    -I$(ENGINE)/src/crypto \
    -I$(ENGINE)/src/display \
    -I$(ENGINE)/src/display/gl \
    -I$(ENGINE)/src/display/libnsgif \
    -I$(ENGINE)/src/etc \
    -I$(ENGINE)/src/filesystem \
    -I$(ENGINE)/src/input \
    -I$(ENGINE)/src/net \
    -I$(ENGINE)/src/system \
    -I$(ENGINE)/src/theoraplay \
    -I$(ENGINE)/src/util \
    -I$(ENGINE)/binding \
    -I$(ENGINE)/shader \
    -I$(ENGINE)/hmode7/src \
    -I$(INCLUDEDIR)/SDL2 \
    -I$(INCLUDEDIR)/pixman-1 \
    -I$(INCLUDEDIR)/uchardet \
    -I$(INCLUDEDIR)/freetype2 \
    -I$(INCLUDEDIR) \
    -I${PWD}/ANGLE/$(SDK)/include

# Same preprocessor defines project.yml hands Xcode for the binding
# compile, EXCEPT MKXPZ_RUBY_VERSION (per-version) and
# MKXPZ_HAVE_SYNTAX_TRANSFORM_PATCHES (3.1-only). Quoting note:
# project.yml escapes the string-literal defines for YAML; here we
# pass them through the shell, so the inner quotes need to survive
# both make's and the shell's expansion.
MKXPZ_DEFINES_30 := \
    -DMKXPZ_BUILD_XCODE \
    -DMKXPZ_ALCDEVICE=ALCdevice \
    -DMKXPZ_VERSION='"1.0.0"' \
    -DMKXPZ_GIT_HASH='"ios"' \
    -DMKXPZ_RUBY_VERSION='"3.0"' \
    -DMKXPZ_RUBY_VERSION_MAJOR=3 \
    -DMKXPZ_RUBY_VERSION_MINOR=0 \
    -DGLES2_HEADER \
    -DMKXPZ_HAS_ANGLE \
    -DHAVE_CONFIG_H \
    -DHM7_HAVE_MKXP_BITMAP

# Suppress the same warnings project.yml suppresses, so the per-Ruby
# binding compile is no noisier than the in-Xcode build.
MKXPZ_WARNFLAGS := \
    -Wno-documentation -Wno-shorten-64-to-32 -Wno-deprecated-declarations \
    -Wno-uninitialized -Wno-conditional-uninitialized -Wno-undefined-var-template \
    -Wno-comma -Wno-switch -Wno-unused-const-variable \
    -Wno-deprecated-literal-operator -Wno-unused-function

mkxp30-merged: init_dirs ruby30 $(LIBDIR)/mkxp30-merged.o
mkxp31-merged: init_dirs ruby     $(LIBDIR)/mkxp31-merged.o
mkxp19-merged: init_dirs ruby19   $(LIBDIR)/mkxp19-merged.o
mkxp18-merged: init_dirs ruby18   $(LIBDIR)/mkxp18-merged.o
mkxp-merged: mkxp18-merged mkxp19-merged mkxp30-merged mkxp31-merged

# 1. Compile every mkxp-z binding/*.cpp against Ruby 3.0 headers.
# 2. ld -r merges them with libruby.3.0-static.a + libruby.3.0-ext.a.
# 3. Unexport list demotes every Ruby-defined symbol to local.
#
# Output: a single relocatable .o file. The host links it like any
# other object; the symbols inside are private-extern so a sister
# mkxp31-merged.o (or mkxp19, mkxp18) can sit alongside without
# conflict.
$(LIBDIR)/mkxp30-merged.o: $(LIBDIR)/libruby.3.0-static.a \
                          $(LIBDIR)/libruby.3.0-ext.a \
                          ${PWD}/multiruby/wrapper.cpp
	@echo "[mkxp30] Compiling binding/*.cpp against Ruby 3.0..."
	@mkdir -p $(BINDING_OBJDIR_30)
	@for src in $(ENGINE)/binding/*.cpp $(ENGINE)/hmode7/src/*.cpp; do \
	    obj=$(BINDING_OBJDIR_30)/$$(basename $$src .cpp).o; \
	    echo "  -> $$(basename $$obj)"; \
	    $(CXX) -isysroot $(SYSROOT) $(TARGET_FLAG) \
	        -std=c++14 -fdeclspec -fobjc-arc -O3 \
	        $(MKXPZ_INCLUDES_30) $(MKXPZ_DEFINES_30) $(MKXPZ_WARNFLAGS) \
	        -c $$src -o $$obj || exit 1; \
	done
	@echo "[mkxp30] Compiling per-version wrapper..."
	@$(CXX) -isysroot $(SYSROOT) $(TARGET_FLAG) \
	    -std=c++14 -fdeclspec -O3 \
	    -DMULTIRUBY_SUFFIX=_30 \
	    $(MKXPZ_INCLUDES_30) \
	    -c ${PWD}/multiruby/wrapper.cpp \
	    -o $(BINDING_OBJDIR_30)/_multiruby_wrapper.o
	@echo "[mkxp30] Generating unexport list..."
	@# Unexport: every libruby symbol + every binding-internal symbol
	@# EXCEPT the wrapper's single versioned entry point. We get the
	@# binding-internals by nm-ing the per-version binding objects;
	@# the wrapper's `_mkxp_get_script_binding_30` is filtered out.
	${PWD}/tools/generate-ruby-unexports.sh \
	    $(LIBDIR)/libruby.3.0-static.a $(LIBDIR)/libruby.3.0-ext.a \
	    > $(BUILD_PREFIX)/ruby30-unexports.txt
	@nm -gU $(BINDING_OBJDIR_30)/*.o 2>/dev/null \
	    | awk '/^[0-9a-f]+ [TDSR] /{print $$3}' \
	    | sort -u \
	    | grep -v '^_mkxp_get_script_binding_30$$' \
	    >> $(BUILD_PREFIX)/ruby30-unexports.txt
	@echo "[mkxp30] Merging via ld -r..."
	@LD=$$(xcrun --sdk $(SDK) -f ld); \
	"$$LD" -r -arch $(ARCH) \
	    $(LD_PLATFORM_VERSION) \
	    -syslibroot $(SYSROOT) \
	    -unexported_symbols_list $(BUILD_PREFIX)/ruby30-unexports.txt \
	    $(LIBDIR)/libruby.3.0-static.a \
	    $(LIBDIR)/libruby.3.0-ext.a \
	    $(BINDING_OBJDIR_30)/*.o \
	    -o $(LIBDIR)/mkxp30-merged.o
	@echo "[mkxp30] Verifying merged .o..."
	@TGLOBALS=$$(nm $(LIBDIR)/mkxp30-merged.o | awk '$$2 == "T"' | sort -u | wc -l | tr -d ' '); \
	echo "  global T symbols (should be 1: _mkxp_get_script_binding_30): $$TGLOBALS"
	@nm $(LIBDIR)/mkxp30-merged.o | awk '$$2 == "T"' | head -3

# Ruby 3.1 — same shape as the 3.0 recipe above. Includes are
# anchored at the global $(INCLUDEDIR) (3.1's traditional install
# location) rather than $(INCLUDEDIR)/ruby31, since the existing
# `ruby` make target installs there. Once 3.1 is migrated to a
# per-version subdir like 3.0, the include line gets updated.
#
# Defines mirror project.yml: includes MKXPZ_HAVE_SYNTAX_TRANSFORM_PATCHES
# (still needed for the 3.1 build until syntax-transform/ is removed).
BINDING_OBJDIR_31 := $(BUILD_PREFIX)/binding31

MKXPZ_INCLUDES_31 := \
    -I$(INCLUDEDIR)/ruby31 \
    -I$(ENGINE) \
    -I$(ENGINE)/src \
    -I$(ENGINE)/src/audio \
    -I$(ENGINE)/src/crypto \
    -I$(ENGINE)/src/display \
    -I$(ENGINE)/src/display/gl \
    -I$(ENGINE)/src/display/libnsgif \
    -I$(ENGINE)/src/etc \
    -I$(ENGINE)/src/filesystem \
    -I$(ENGINE)/src/input \
    -I$(ENGINE)/src/net \
    -I$(ENGINE)/src/system \
    -I$(ENGINE)/src/theoraplay \
    -I$(ENGINE)/src/util \
    -I$(ENGINE)/binding \
    -I$(ENGINE)/shader \
    -I$(ENGINE)/hmode7/src \
    -I$(INCLUDEDIR)/SDL2 \
    -I$(INCLUDEDIR)/pixman-1 \
    -I$(INCLUDEDIR)/uchardet \
    -I$(INCLUDEDIR)/freetype2 \
    -I$(INCLUDEDIR) \
    -I${PWD}/ANGLE/$(SDK)/include

MKXPZ_DEFINES_31 := \
    -DMKXPZ_BUILD_XCODE \
    -DMKXPZ_ALCDEVICE=ALCdevice \
    -DMKXPZ_VERSION='"1.0.0"' \
    -DMKXPZ_GIT_HASH='"ios"' \
    -DMKXPZ_RUBY_VERSION='"3.1"' \
    -DMKXPZ_RUBY_VERSION_MAJOR=3 \
    -DMKXPZ_RUBY_VERSION_MINOR=1 \
    -DMKXPZ_HAVE_SYNTAX_TRANSFORM_PATCHES \
    -DGLES2_HEADER \
    -DMKXPZ_HAS_ANGLE \
    -DHAVE_CONFIG_H \
    -DHM7_HAVE_MKXP_BITMAP

$(LIBDIR)/mkxp31-merged.o: $(LIBDIR)/libruby.3.1-static.a \
                          $(LIBDIR)/libruby.3.1-ext.a \
                          ${PWD}/multiruby/wrapper.cpp
	@echo "[mkxp31] Compiling binding/*.cpp + hmode7/*.cpp against Ruby 3.1..."
	@mkdir -p $(BINDING_OBJDIR_31)
	@for src in $(ENGINE)/binding/*.cpp $(ENGINE)/hmode7/src/*.cpp; do \
	    obj=$(BINDING_OBJDIR_31)/$$(basename $$src .cpp).o; \
	    echo "  -> $$(basename $$obj)"; \
	    $(CXX) -isysroot $(SYSROOT) $(TARGET_FLAG) \
	        -std=c++14 -fdeclspec -fobjc-arc -O3 \
	        $(MKXPZ_INCLUDES_31) $(MKXPZ_DEFINES_31) $(MKXPZ_WARNFLAGS) \
	        -c $$src -o $$obj || exit 1; \
	done
	@echo "[mkxp31] Compiling per-version wrapper..."
	@$(CXX) -isysroot $(SYSROOT) $(TARGET_FLAG) \
	    -std=c++14 -fdeclspec -O3 \
	    -DMULTIRUBY_SUFFIX=_31 \
	    $(MKXPZ_INCLUDES_31) \
	    -c ${PWD}/multiruby/wrapper.cpp \
	    -o $(BINDING_OBJDIR_31)/_multiruby_wrapper.o
	@echo "[mkxp31] Generating unexport list..."
	${PWD}/tools/generate-ruby-unexports.sh \
	    $(LIBDIR)/libruby.3.1-static.a $(LIBDIR)/libruby.3.1-ext.a \
	    > $(BUILD_PREFIX)/ruby31-unexports.txt.raw
	@nm -gU $(BINDING_OBJDIR_31)/*.o 2>/dev/null \
	    | awk '/^[0-9a-f]+ [TDSR] /{print $$3}' \
	    | sort -u \
	    | grep -v '^_mkxp_get_script_binding_31$$' \
	    >> $(BUILD_PREFIX)/ruby31-unexports.txt.raw
	@# Carve out symbols that need to remain externally visible:
	@# main.cpp (Xcode-compiled) sets the syntax-transform target
	@# version variables defined in libruby.3.1's parse.y patch.
	@# Leaving them hidden inside mkxp31-merged.o is fine for the
	@# binding's local use but breaks main.cpp's link. These exist
	@# only in 3.1 (3.0 doesn't have the syntax-transform patches),
	@# so there's no risk of duplicate-symbol clashes when both
	@# merged.o files are linked together.
	@grep -vE '^_mkxp_syntax_transform_target_ruby_version_(major|minor|teeny)$$' \
	    $(BUILD_PREFIX)/ruby31-unexports.txt.raw \
	    > $(BUILD_PREFIX)/ruby31-unexports.txt
	@rm -f $(BUILD_PREFIX)/ruby31-unexports.txt.raw
	@echo "[mkxp31] Merging via ld -r..."
	@LD=$$(xcrun --sdk $(SDK) -f ld); \
	"$$LD" -r -arch $(ARCH) \
	    $(LD_PLATFORM_VERSION) \
	    -syslibroot $(SYSROOT) \
	    -unexported_symbols_list $(BUILD_PREFIX)/ruby31-unexports.txt \
	    $(LIBDIR)/libruby.3.1-static.a \
	    $(LIBDIR)/libruby.3.1-ext.a \
	    $(BINDING_OBJDIR_31)/*.o \
	    -o $(LIBDIR)/mkxp31-merged.o
	@echo "[mkxp31] Verifying merged .o..."
	@TGLOBALS=$$(nm $(LIBDIR)/mkxp31-merged.o | awk '$$2 == "T"' | sort -u | wc -l | tr -d ' '); \
	echo "  global T symbols (should be 1: _mkxp_get_script_binding_31): $$TGLOBALS"
	@nm $(LIBDIR)/mkxp31-merged.o | awk '$$2 == "T"' | head -3

# Ruby 1.9 + 1.8 mkxp merged.o targets — same shape as 3.0/3.1 above.
# RAPI macros in binding-util.h gate the C-API differences; we hand
# each Ruby version its own header dir + matching MKXPZ_RUBY_VERSION
# define.
BINDING_OBJDIR_19 := $(BUILD_PREFIX)/binding19
BINDING_OBJDIR_18 := $(BUILD_PREFIX)/binding18

MKXPZ_INCLUDES_19 := \
    -I$(INCLUDEDIR)/ruby19 \
    -I$(ENGINE) \
    -I$(ENGINE)/src \
    -I$(ENGINE)/src/audio \
    -I$(ENGINE)/src/crypto \
    -I$(ENGINE)/src/display \
    -I$(ENGINE)/src/display/gl \
    -I$(ENGINE)/src/display/libnsgif \
    -I$(ENGINE)/src/etc \
    -I$(ENGINE)/src/filesystem \
    -I$(ENGINE)/src/input \
    -I$(ENGINE)/src/net \
    -I$(ENGINE)/src/system \
    -I$(ENGINE)/src/theoraplay \
    -I$(ENGINE)/src/util \
    -I$(ENGINE)/binding \
    -I$(ENGINE)/shader \
    -I$(ENGINE)/hmode7/src \
    -I$(INCLUDEDIR)/SDL2 \
    -I$(INCLUDEDIR)/pixman-1 \
    -I$(INCLUDEDIR)/uchardet \
    -I$(INCLUDEDIR)/freetype2 \
    -I$(INCLUDEDIR) \
    -I${PWD}/ANGLE/$(SDK)/include

MKXPZ_DEFINES_19 := \
    -DMKXPZ_BUILD_XCODE \
    -DMKXPZ_ALCDEVICE=ALCdevice \
    -DMKXPZ_VERSION='"1.0.0"' \
    -DMKXPZ_GIT_HASH='"ios"' \
    -DMKXPZ_RUBY_VERSION='"1.9"' \
    -DMKXPZ_RUBY_VERSION_MAJOR=1 \
    -DMKXPZ_RUBY_VERSION_MINOR=9 \
    -DGLES2_HEADER \
    -DMKXPZ_HAS_ANGLE \
    -DHAVE_CONFIG_H \
    -DHM7_HAVE_MKXP_BITMAP

MKXPZ_INCLUDES_18 := \
    -I$(ENGINE) \
    -I$(ENGINE)/src \
    -I$(ENGINE)/src/audio \
    -I$(ENGINE)/src/crypto \
    -I$(ENGINE)/src/display \
    -I$(ENGINE)/src/display/gl \
    -I$(ENGINE)/src/display/libnsgif \
    -I$(ENGINE)/src/etc \
    -I$(ENGINE)/src/filesystem \
    -I$(ENGINE)/src/input \
    -I$(ENGINE)/src/net \
    -I$(ENGINE)/src/system \
    -I$(ENGINE)/src/theoraplay \
    -I$(ENGINE)/src/util \
    -I$(ENGINE)/binding \
    -I$(ENGINE)/shader \
    -I$(ENGINE)/hmode7/src \
    -I$(INCLUDEDIR)/SDL2 \
    -I$(INCLUDEDIR)/pixman-1 \
    -I$(INCLUDEDIR)/uchardet \
    -I$(INCLUDEDIR)/freetype2 \
    -I$(INCLUDEDIR) \
    -I${PWD}/ANGLE/$(SDK)/include \
    -I$(INCLUDEDIR)/ruby18

MKXPZ_DEFINES_18 := \
    -DMKXPZ_BUILD_XCODE \
    -DMKXPZ_ALCDEVICE=ALCdevice \
    -DMKXPZ_VERSION='"1.0.0"' \
    -DMKXPZ_GIT_HASH='"ios"' \
    -DMKXPZ_RUBY_VERSION='"1.8"' \
    -DMKXPZ_RUBY_VERSION_MAJOR=1 \
    -DMKXPZ_RUBY_VERSION_MINOR=8 \
    -DGLES2_HEADER \
    -DMKXPZ_HAS_ANGLE \
    -DHAVE_CONFIG_H \
    -DHM7_HAVE_MKXP_BITMAP

$(LIBDIR)/mkxp19-merged.o: $(LIBDIR)/libruby19-static.a \
                          $(LIBDIR)/libruby19-ext.a \
                          ${PWD}/multiruby/wrapper.cpp
	@echo "[mkxp19] Compiling binding/*.cpp + hmode7/*.cpp against Ruby 1.9..."
	@mkdir -p $(BINDING_OBJDIR_19)
	@for src in $(ENGINE)/binding/*.cpp $(ENGINE)/hmode7/src/*.cpp; do \
	    obj=$(BINDING_OBJDIR_19)/$$(basename $$src .cpp).o; \
	    echo "  -> $$(basename $$obj)"; \
	    $(CXX) -isysroot $(SYSROOT) $(TARGET_FLAG) \
	        -std=c++14 -fdeclspec -fobjc-arc -O3 \
	        $(MKXPZ_INCLUDES_19) $(MKXPZ_DEFINES_19) $(MKXPZ_WARNFLAGS) \
	        -c $$src -o $$obj || exit 1; \
	done
	@echo "[mkxp19] Compiling per-version wrapper..."
	@$(CXX) -isysroot $(SYSROOT) $(TARGET_FLAG) \
	    -std=c++14 -fdeclspec -O3 \
	    -DMULTIRUBY_SUFFIX=_19 \
	    $(MKXPZ_INCLUDES_19) \
	    -c ${PWD}/multiruby/wrapper.cpp \
	    -o $(BINDING_OBJDIR_19)/_multiruby_wrapper.o
	@echo "[mkxp19] Generating unexport list..."
	${PWD}/tools/generate-ruby-unexports.sh \
	    $(LIBDIR)/libruby19-static.a \
	    > $(BUILD_PREFIX)/ruby19-unexports.txt
	@# Also include ext.a's exports (Init_zlib etc.) so they don't
	@# leak across merged.o boundaries.
	${PWD}/tools/generate-ruby-unexports.sh \
	    $(LIBDIR)/libruby19-ext.a \
	    >> $(BUILD_PREFIX)/ruby19-unexports.txt
	@nm -gU $(BINDING_OBJDIR_19)/*.o 2>/dev/null \
	    | awk '/^[0-9a-f]+ [TDSR] /{print $$3}' \
	    | sort -u \
	    | grep -v '^_mkxp_get_script_binding_19$$' \
	    >> $(BUILD_PREFIX)/ruby19-unexports.txt
	@echo "[mkxp19] Merging via ld -r..."
	@LD=$$(xcrun --sdk $(SDK) -f ld); \
	"$$LD" -r -arch $(ARCH) \
	    $(LD_PLATFORM_VERSION) \
	    -syslibroot $(SYSROOT) \
	    -unexported_symbols_list $(BUILD_PREFIX)/ruby19-unexports.txt \
	    $(LIBDIR)/libruby19-static.a \
	    $(LIBDIR)/libruby19-ext.a \
	    $(BINDING_OBJDIR_19)/*.o \
	    -o $(LIBDIR)/mkxp19-merged.o
	@echo "[mkxp19] Verifying merged .o..."
	@TGLOBALS=$$(nm $(LIBDIR)/mkxp19-merged.o | awk '$$2 == "T"' | sort -u | wc -l | tr -d ' '); \
	echo "  global T symbols (should be 1: _mkxp_get_script_binding_19): $$TGLOBALS"
	@nm $(LIBDIR)/mkxp19-merged.o | awk '$$2 == "T"' | head -3

$(LIBDIR)/mkxp18-merged.o: $(LIBDIR)/libruby18-static.a \
                          $(LIBDIR)/libruby18-ext.a \
                          ${PWD}/multiruby/wrapper.cpp
	@echo "[mkxp18] Compiling binding/*.cpp + hmode7/*.cpp against Ruby 1.8..."
	@mkdir -p $(BINDING_OBJDIR_18)
	@for src in $(ENGINE)/binding/*.cpp $(ENGINE)/hmode7/src/*.cpp; do \
	    obj=$(BINDING_OBJDIR_18)/$$(basename $$src .cpp).o; \
	    echo "  -> $$(basename $$obj)"; \
	    $(CXX) -isysroot $(SYSROOT) $(TARGET_FLAG) \
	        -std=c++14 -fdeclspec -fobjc-arc -O3 \
	        $(MKXPZ_INCLUDES_18) $(MKXPZ_DEFINES_18) $(MKXPZ_WARNFLAGS) \
	        -c $$src -o $$obj || exit 1; \
	done
	@echo "[mkxp18] Compiling per-version wrapper..."
	@$(CXX) -isysroot $(SYSROOT) $(TARGET_FLAG) \
	    -std=c++14 -fdeclspec -O3 \
	    -DMULTIRUBY_SUFFIX=_18 \
	    $(MKXPZ_INCLUDES_18) \
	    -c ${PWD}/multiruby/wrapper.cpp \
	    -o $(BINDING_OBJDIR_18)/_multiruby_wrapper.o
	@echo "[mkxp18] Generating unexport list..."
	${PWD}/tools/generate-ruby-unexports.sh \
	    $(LIBDIR)/libruby18-static.a \
	    > $(BUILD_PREFIX)/ruby18-unexports.txt
	@# Also include ext.a's exports (Init_zlib etc.) in the
	@# unexport list so they don't leak across merged.o boundaries.
	${PWD}/tools/generate-ruby-unexports.sh \
	    $(LIBDIR)/libruby18-ext.a \
	    >> $(BUILD_PREFIX)/ruby18-unexports.txt
	@nm -gU $(BINDING_OBJDIR_18)/*.o 2>/dev/null \
	    | awk '/^[0-9a-f]+ [TDSR] /{print $$3}' \
	    | sort -u \
	    | grep -v '^_mkxp_get_script_binding_18$$' \
	    >> $(BUILD_PREFIX)/ruby18-unexports.txt
	@echo "[mkxp18] Merging via ld -r..."
	@LD=$$(xcrun --sdk $(SDK) -f ld); \
	"$$LD" -r -arch $(ARCH) \
	    $(LD_PLATFORM_VERSION) \
	    -syslibroot $(SYSROOT) \
	    -unexported_symbols_list $(BUILD_PREFIX)/ruby18-unexports.txt \
	    $(LIBDIR)/libruby18-static.a \
	    $(LIBDIR)/libruby18-ext.a \
	    $(BINDING_OBJDIR_18)/*.o \
	    -o $(LIBDIR)/mkxp18-merged.o
	@echo "[mkxp18] Verifying merged .o..."
	@TGLOBALS=$$(nm $(LIBDIR)/mkxp18-merged.o | awk '$$2 == "T"' | sort -u | wc -l | tr -d ' '); \
	echo "  global T symbols (should be 1: _mkxp_get_script_binding_18): $$TGLOBALS"
	@nm $(LIBDIR)/mkxp18-merged.o | awk '$$2 == "T"' | head -3

# Ruby 1.8 (submodule: sources/ruby18)
ruby18: init_dirs $(LIBDIR)/libruby18-static.a

# Ruby 1.9 (submodule: sources/ruby19)
#
# 1.9.3-p551 builds for iOS arm64 with a small, surgical patch:
#   - aarch64-darwin-fake.rb: cross-compile fake config so the host
#     ruby (which we run as MINIRUBY in cross mode) reports as the
#     1.9.3 target instead of itself, otherwise tool/mkconfig.rb
#     refuses with "ruby lib version doesn't match executable
#     version". Same approach as Ruby 1.8.
#   - tool/config.{sub,guess}: replaced with modern savannah versions
#     so aarch64-apple-darwin canonicalizes correctly. The shipped
#     1.9 versions are too old to recognize aarch64.
#   - process.c: gate system() behind TARGET_OS_IPHONE (unavailable
#     on iOS, same as 3.0/3.1's ios.patch).
#
# The MINIRUBY override below uses --disable=gems so the host ruby
# doesn't try to load its own rbconfig before our fake.rb runs
# (rubygems' gem_prelude.rb requires rbconfig at startup, which then
# triggers the version mismatch check).
#
# We use --host=aarch64-unknown-darwin (3-tuple with explicit unknown
# vendor) instead of aarch64-apple-darwin because 1.9's autoconf
# 2.59-era target_cpu extraction empties the cpu field for the apple
# vendor case.
ruby19: init_dirs $(LIBDIR)/libruby19-static.a

RUBY19_CFLAGS = $(TARGETFLAGS) -std=gnu89 -O2 \
	-Wno-implicit-function-declaration \
	-Wno-implicit-int \
	-Wno-incompatible-pointer-types \
	-Wno-int-conversion \
	-Wno-deprecated-non-prototype \
	-Wno-incompatible-function-pointer-types \
	-Wno-compound-token-split-by-macro

# Mirrors RUBY18_EXTS. Note: `thread` is NOT a separate ext in 1.9
# (folded into core); pathname is added because Pokemon Essentials
# uses it.
RUBY19_EXTS = zlib stringio strscan digest fcntl pathname

$(LIBDIR)/libruby19-static.a: $(SOURCES)/ruby19/Makefile
	cd $(SOURCES)/ruby19; \
	$(CONFIGURE_ENV) make -j$(NPROC) libruby-static.a; \
	cp libruby-static.a $(LIBDIR)/libruby19-static.a; \
	mkdir -p $(INCLUDEDIR)/ruby19; \
	cp -R include/* $(INCLUDEDIR)/ruby19/; \
	cp .ext/include/aarch64-darwin/ruby/config.h $(INCLUDEDIR)/ruby19/ruby/config.h 2>/dev/null || true
	@# Build extensions (mirrors the Ruby 1.8 pattern; see
	@# libruby18-static.a recipe). Adds our hand-rolled extinit.c
	@# which provides the real Init_ext() calling each Init_X.
	@EXTCFLAGS="$(RUBY19_CFLAGS) -I$(SOURCES)/ruby19 -I$(SOURCES)/ruby19/include -I$(SOURCES)/ruby19/.ext/include/aarch64-darwin -I$(INCLUDEDIR)/ruby19"; \
	OBJ_FILES=""; \
	for ext in $(RUBY19_EXTS); do \
		for src in $(SOURCES)/ruby19/ext/$$ext/*.c; do \
			obj=$${src%.c}.o; \
			$(CC) $$EXTCFLAGS -c $$src -o $$obj; \
			OBJ_FILES="$$OBJ_FILES $$obj"; \
		done; \
	done; \
	$(CC) $$EXTCFLAGS \
		-c ${PWD}/ruby19/extinit.c \
		-o $(SOURCES)/ruby19/extinit.o; \
	OBJ_FILES="$(SOURCES)/ruby19/extinit.o $$OBJ_FILES"; \
	$(AR) rcs $(LIBDIR)/libruby19-ext.a $$OBJ_FILES; \
	$(RANLIB) $(LIBDIR)/libruby19-ext.a
	@# Strip dmyext.o from libruby19-static.a so libruby19-ext.a's
	@# Init_ext wins at link time.
	$(AR) d $(LIBDIR)/libruby19-static.a dmyext.o || true
	$(RANLIB) $(LIBDIR)/libruby19-static.a

$(SOURCES)/ruby19/Makefile: $(SOURCES)/ruby19/configure
	cd $(SOURCES)/ruby19; \
	export $(CONFIGURE_ENV); \
	export CFLAGS="$(RUBY19_CFLAGS) $$CFLAGS"; \
	export LDFLAGS="$$LDFLAGS"; \
	./configure \
		--host=aarch64-unknown-darwin \
		--build=aarch64-unknown-darwin \
		--target=aarch64-unknown-darwin \
		--prefix="$(BUILD_PREFIX)" \
		--disable-shared \
		--with-static-linked-ext \
		--disable-rubygems \
		--disable-install-doc \
		cross_compiling=yes \
		ac_cv_func_fork=no; \
	sed -i '' 's|^BASERUBY = ruby$$|BASERUBY = ruby --disable=gems|' Makefile; \
	sed -i '' 's|^MINIRUBY = ruby |MINIRUBY = ruby --disable=gems |' Makefile

$(SOURCES)/ruby19/configure: $(SOURCES)/ruby19/configure.in
	cd $(SOURCES)/ruby19; \
	git checkout -- . 2>/dev/null; \
	git clean -fdxq 2>/dev/null; \
	rm -f aarch64-darwin-fake.rb arm64-darwin-fake.rb; \
	git apply $(PATCHES)/ruby19/ios.patch; \
	autoconf

RUBY18_CFLAGS = $(TARGETFLAGS) -std=gnu89 -O2 \
	-fno-stack-protector \
	-fno-strict-aliasing \
	-fwrapv \
	-Wno-implicit-function-declaration \
	-Wno-implicit-int \
	-Wno-incompatible-pointer-types \
	-Wno-int-conversion \
	-Wno-deprecated-non-prototype \
	-Wno-incompatible-function-pointer-types

# Ruby 1.8 stdlib extensions to bundle into mkxp18-merged.o.
#
# `thread` was previously here but caused EXC_BAD_ACCESS in
# rb_thread_s_new (NULL deref at 0x15) when our hand-rolled
# Init_ext() force-initialized it on top of Ruby 1.8's already-built-in
# threading core. Removed; the core Thread class still works without
# it.
RUBY18_EXTS = zlib stringio strscan digest fcntl

$(LIBDIR)/libruby18-static.a: $(SOURCES)/ruby18/Makefile
	cd $(SOURCES)/ruby18; \
	$(CONFIGURE_ENV) CFLAGS="$(RUBY18_CFLAGS)" make -j$(NPROC) COMPILE_PRELUDE=true libruby-static.a; \
	cp libruby-static.a $(LIBDIR)/libruby18-static.a; \
	mkdir -p $(INCLUDEDIR)/ruby18; \
	cp *.h $(INCLUDEDIR)/ruby18/
	@# Compile our PAC-free arm64 setjmp/longjmp replacement and
	@# inject it into libruby18-static.a. Apple's _setjmp signs LR
	@# with PACIBSP using SP as the modifier; Ruby 1.8's green
	@# threading longjmps onto a different stack, so PAC verify
	@# fails. The asm replacement saves/restores LR raw - no PAC.
	@# config.h is patched (in ios.patch) to point RUBY_SETJMP /
	@# RUBY_LONGJMP at our symbols.
	$(CC) $(TARGETFLAGS) -c ${PWD}/ruby18/mkxp_setjmp_arm64.S \
		-o $(SOURCES)/ruby18/mkxp_setjmp_arm64.o
	$(AR) rcs $(LIBDIR)/libruby18-static.a $(SOURCES)/ruby18/mkxp_setjmp_arm64.o
	$(RANLIB) $(LIBDIR)/libruby18-static.a
	@# Build extensions (use Ruby 1.8 headers only, not $(INCLUDEDIR) which has Ruby 3.1)
	@# Builds per-ext .o files, plus our hand-rolled extinit.c (which
	@# replaces dmyext.o's empty Init_ext at link time so Init_zlib /
	@# Init_stringio / etc. fire at Ruby startup; iOS can't dlopen).
	@EXTCFLAGS="$(RUBY18_CFLAGS) -I$(SOURCES)/ruby18 -I$(SOURCES)/ruby18/include -I$(INCLUDEDIR)"; \
	OBJ_FILES=""; \
	for ext in $(RUBY18_EXTS); do \
		for src in $(SOURCES)/ruby18/ext/$$ext/*.c; do \
			obj=$${src%.c}.o; \
			$(CC) $$EXTCFLAGS -c $$src -o $$obj; \
			OBJ_FILES="$$OBJ_FILES $$obj"; \
		done; \
	done; \
	$(CC) $$EXTCFLAGS \
		-c ${PWD}/ruby18/extinit.c \
		-o $(SOURCES)/ruby18/extinit.o; \
	OBJ_FILES="$(SOURCES)/ruby18/extinit.o $$OBJ_FILES"; \
	$(AR) rcs $(LIBDIR)/libruby18-ext.a $$OBJ_FILES; \
	$(RANLIB) $(LIBDIR)/libruby18-ext.a
	@# Strip dmyext.o from libruby18-static.a so the real Init_ext
	@# from libruby18-ext.a wins at link time (mirrors the 3.0/3.1
	@# recipe's `$(AR) d ... dmyext.o` trick).
	$(AR) d $(LIBDIR)/libruby18-static.a dmyext.o || true
	$(RANLIB) $(LIBDIR)/libruby18-static.a

$(SOURCES)/ruby18/Makefile: $(SOURCES)/ruby18/configure
	cd $(SOURCES)/ruby18; \
	$(CONFIGURE_ENV) CFLAGS="$(RUBY18_CFLAGS)" \
	./configure \
		--host=$(HOST) \
		--build=x86_64-apple-darwin \
		--prefix="$(BUILD_PREFIX)" \
		--disable-shared \
		--enable-static \
		--with-static-linked-ext; \
	touch prelude.c
	@# Override config.h's RUBY_SETJMP / RUBY_LONGJMP to point at
	@# our PAC-free arm64 setjmp variant (see mkxp_setjmp_arm64.S).
	@# Configure picks `_setjmp` based on HAVE__SETJMP detection;
	@# Apple's `_setjmp` signs LR with PAC, breaking Ruby 1.8's
	@# stack-swapping green threading. Our replacement uses raw LR
	@# save/restore.
	sed -i '' \
		-e 's|^#define RUBY_SETJMP(env) _setjmp(env)$$|#define RUBY_SETJMP(env) mkxp_ruby18_setjmp(env)|' \
		-e 's|^#define RUBY_LONGJMP(env,val) _longjmp(env,val)$$|#define RUBY_LONGJMP(env,val) mkxp_ruby18_longjmp(env,val)|' \
		$(SOURCES)/ruby18/config.h
	@# Inject prototypes; eval.c relies on the system header for
	@# _setjmp prototypes which won't match our names.
	@# CRITICAL: returns_twice attribute tells the compiler this is
	@# a setjmp-like function. Without it, locals live across the
	@# call may stay in registers and not be reloaded after longjmp,
	@# producing corrupted state on the second return. Apple's
	@# `_setjmp` is special-cased by clang automatically; ours isn't.
	echo '' >> $(SOURCES)/ruby18/config.h
	echo 'extern int  mkxp_ruby18_setjmp(void *env) __attribute__((returns_twice));' >> $(SOURCES)/ruby18/config.h
	echo 'extern void mkxp_ruby18_longjmp(void *env, int val) __attribute__((noreturn));' >> $(SOURCES)/ruby18/config.h

$(SOURCES)/ruby18/configure: $(SOURCES)/ruby18/configure.in
	cd $(SOURCES)/ruby18; \
	git checkout -- . 2>/dev/null; \
	git clean -fdx 2>/dev/null; \
	git apply $(PATCHES)/ruby18/ios.patch; \
	autoconf

# ====
init_dirs:
	@mkdir -p $(LIBDIR) $(INCLUDEDIR)

# Fetch vendored sources for SDL_image (must run once after submodule init)
sdl2image-vendored: $(SOURCES)/sdl2_image/external/download.sh
	cd $(SOURCES)/sdl2_image; ./external/download.sh

clean: clean-compiled

powerwash: clean-compiled clean-downloads

clean-downloads:
	-rm -rf downloads/$(HOST)

clean-compiled:
	-rm -rf build-$(SDK)-$(ARCH)

# Clean build artifacts from submodule source trees (configure outputs, object files, etc.)
clean-sources:
	@for dir in sdl2 sdl2_image sdl2_ttf sdl_sound freetype ruby openal-soft; do \
		rm -rf $(SOURCES)/$$dir/cmakebuild 2>/dev/null; \
	done
	cd $(SOURCES)/sdl2_ttf && git checkout -- . 2>/dev/null || true
	cd $(SOURCES)/freetype && git checkout -- . 2>/dev/null || true
	cd $(SOURCES)/ruby && git checkout -- . 2>/dev/null || true
	cd $(SOURCES)/ruby18 && git checkout -- . 2>/dev/null || true

deps-core: libtheora libvorbis pixman libpng physfs uchardet sdl2 sdl2image sdlsound sdl2ttf freetype openal
everything: deps-core ruby ruby18
