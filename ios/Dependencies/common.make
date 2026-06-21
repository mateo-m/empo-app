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
# Per-SDK tag for isolated autotools/cmake build dirs. Never share
# configure output between iphoneos and iphonesimulator — see
# BUILD_PIPELINE_ISSUES.md issues 3 and 7.
SDK_TAG := $(SDK)-$(ARCH)
CMAKE_BUILDDIR := cmakebuild-$(SDK_TAG)
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

$(DOWNLOADS)/theora/.configured-$(SDK_TAG): $(DOWNLOADS)/theora/configure
	cd $(DOWNLOADS)/theora; $(MAKE) distclean 2>/dev/null || true
	cd $(DOWNLOADS)/theora; \
	$(CONFIGURE) --with-ogg=$(BUILD_PREFIX) --enable-shared=false --enable-static=true --disable-examples
	touch $@

$(DOWNLOADS)/theora/Makefile: $(DOWNLOADS)/theora/.configured-$(SDK_TAG)

$(DOWNLOADS)/theora/configure: $(DOWNLOADS)/theora/autogen.sh
	cd $(DOWNLOADS)/theora; \
	./autogen.sh

$(DOWNLOADS)/theora/autogen.sh:
	$(CLONE) $(GITHUB)/xiph/theora $(DOWNLOADS)/theora

# Vorbis
libvorbis: init_dirs libogg $(LIBDIR)/libvorbis.a

$(LIBDIR)/libvorbis.a: $(LIBDIR)/libogg.a $(DOWNLOADS)/vorbis/$(CMAKE_BUILDDIR)/Makefile
	cd $(DOWNLOADS)/vorbis/$(CMAKE_BUILDDIR); \
	make -j$(NPROC); make install

$(DOWNLOADS)/vorbis/$(CMAKE_BUILDDIR)/Makefile: $(DOWNLOADS)/vorbis/CMakeLists.txt
	cd $(DOWNLOADS)/vorbis; \
	mkdir -p $(CMAKE_BUILDDIR); cd $(CMAKE_BUILDDIR); \
	$(CMAKE) -DBUILD_SHARED_LIBS=no

$(DOWNLOADS)/vorbis/CMakeLists.txt:
	$(CLONE) $(GITHUB)/xiph/vorbis -b v1.3.7 $(DOWNLOADS)/vorbis


# Ogg
libogg: init_dirs $(LIBDIR)/libogg.a

$(LIBDIR)/libogg.a: $(DOWNLOADS)/ogg/Makefile
	cd $(DOWNLOADS)/ogg; \
	make -j$(NPROC); make install

$(DOWNLOADS)/ogg/Makefile: $(DOWNLOADS)/ogg/.configured-$(SDK_TAG)

$(DOWNLOADS)/ogg/.configured-$(SDK_TAG): $(DOWNLOADS)/ogg/configure
	cd $(DOWNLOADS)/ogg; $(MAKE) distclean 2>/dev/null || true
	cd $(DOWNLOADS)/ogg; \
	$(CONFIGURE) --enable-static=true --enable-shared=false
	touch $@

$(DOWNLOADS)/ogg/configure: $(DOWNLOADS)/ogg/autogen.sh
	cd $(DOWNLOADS)/ogg; ./autogen.sh

$(DOWNLOADS)/ogg/autogen.sh:
	$(CLONE) $(GITHUB)/xiph/ogg -b v1.3.6 $(DOWNLOADS)/ogg

# uchardet
uchardet: init_dirs $(LIBDIR)/libuchardet.a

$(LIBDIR)/libuchardet.a: $(DOWNLOADS)/uchardet/$(CMAKE_BUILDDIR)/Makefile
	cd $(DOWNLOADS)/uchardet/$(CMAKE_BUILDDIR); \
	make -j$(NPROC); make install

$(DOWNLOADS)/uchardet/$(CMAKE_BUILDDIR)/Makefile: $(DOWNLOADS)/uchardet/CMakeLists.txt
	cd $(DOWNLOADS)/uchardet; \
	mkdir -p $(CMAKE_BUILDDIR); cd $(CMAKE_BUILDDIR); \
	$(CMAKE) -DBUILD_SHARED_LIBS=no -DBUILD_BINARY=OFF

$(DOWNLOADS)/uchardet/CMakeLists.txt:
	$(CLONE) https://gitlab.freedesktop.org/uchardet/uchardet -b v0.0.8 $(DOWNLOADS)/uchardet


# Pixman
pixman: init_dirs libpng $(LIBDIR)/libpixman-1.a

$(LIBDIR)/libpixman-1.a: $(DOWNLOADS)/pixman/Makefile
	cd $(DOWNLOADS)/pixman
	make -C $(DOWNLOADS)/pixman -j$(NPROC)
	make -C $(DOWNLOADS)/pixman install

$(DOWNLOADS)/pixman/.configured-$(SDK_TAG): $(DOWNLOADS)/pixman/autogen.sh
	cd $(DOWNLOADS)/pixman; $(MAKE) distclean 2>/dev/null || true
	cd $(DOWNLOADS)/pixman; \
	$(AUTOGEN) --enable-static=yes --enable-shared=no \
	--disable-arm-a64-neon
	touch $@

$(DOWNLOADS)/pixman/Makefile: $(DOWNLOADS)/pixman/.configured-$(SDK_TAG)

$(DOWNLOADS)/pixman/autogen.sh:
	$(CLONE) https://gitlab.freedesktop.org/pixman/pixman -b pixman-0.42.2 $(DOWNLOADS)/pixman


# PhysFS
physfs: init_dirs $(LIBDIR)/libphysfs.a

$(LIBDIR)/libphysfs.a: $(DOWNLOADS)/physfs/$(CMAKE_BUILDDIR)/Makefile
	cd $(DOWNLOADS)/physfs/$(CMAKE_BUILDDIR); \
	make -j$(NPROC); make install

$(DOWNLOADS)/physfs/$(CMAKE_BUILDDIR)/Makefile: $(DOWNLOADS)/physfs/CMakeLists.txt
	cd $(DOWNLOADS)/physfs; \
	mkdir -p $(CMAKE_BUILDDIR); cd $(CMAKE_BUILDDIR); \
	$(CMAKE) -DPHYSFS_BUILD_STATIC=true -DPHYSFS_BUILD_SHARED=false -DPHYSFS_BUILD_TEST=false

$(DOWNLOADS)/physfs/CMakeLists.txt:
	$(CLONE) $(GITHUB)/icculus/physfs -b release-3.2.0 $(DOWNLOADS)/physfs

# libpng
libpng: init_dirs $(LIBDIR)/libpng.a

$(LIBDIR)/libpng.a: $(DOWNLOADS)/libpng/Makefile
	cd $(DOWNLOADS)/libpng; \
	make -j$(NPROC); make install

$(DOWNLOADS)/libpng/.configured-$(SDK_TAG): $(DOWNLOADS)/libpng/configure
	cd $(DOWNLOADS)/libpng; $(MAKE) distclean 2>/dev/null || true
	cd $(DOWNLOADS)/libpng; \
	$(CONFIGURE) \
	--enable-shared=no --enable-static=yes
	touch $@

$(DOWNLOADS)/libpng/Makefile: $(DOWNLOADS)/libpng/.configured-$(SDK_TAG)

$(DOWNLOADS)/libpng/configure:
	$(CLONE) $(GITHUB)/pnggroup/libpng -b v1.6.50 $(DOWNLOADS)/libpng

# SDL2 (submodule: sources/sdl2)
sdl2: init_dirs $(LIBDIR)/libSDL2.a

$(LIBDIR)/libSDL2.a: $(SOURCES)/sdl2/$(CMAKE_BUILDDIR)/Makefile
	cd $(SOURCES)/sdl2/$(CMAKE_BUILDDIR); \
	make -j$(NPROC); make install

$(SOURCES)/sdl2/$(CMAKE_BUILDDIR)/Makefile: $(SOURCES)/sdl2/CMakeLists.txt
	cd $(SOURCES)/sdl2; \
	mkdir -p $(CMAKE_BUILDDIR); cd $(CMAKE_BUILDDIR); \
	$(CMAKE) -DBUILD_SHARED_LIBS=no \
	-DSDL_OPENGL=OFF \
	-DSDL_OPENGLES=ON \
	-DSDL_METAL=ON \
	-DSDL_RENDER_METAL=ON

# SDL_image (submodule: sources/sdl2_image)
sdl2image: init_dirs sdl2 $(LIBDIR)/libSDL2_image.a

$(LIBDIR)/libSDL2_image.a: $(SOURCES)/sdl2_image/$(CMAKE_BUILDDIR)/Makefile
	cd $(SOURCES)/sdl2_image/$(CMAKE_BUILDDIR); \
	make -j$(NPROC); make install

$(SOURCES)/sdl2_image/$(CMAKE_BUILDDIR)/Makefile: $(SOURCES)/sdl2_image/CMakeLists.txt
	cd $(SOURCES)/sdl2_image; mkdir -p $(CMAKE_BUILDDIR); cd $(CMAKE_BUILDDIR); \
	$(CMAKE) \
	-DBUILD_SHARED_LIBS=no \
	-DSDL2IMAGE_SAMPLES=no \
	-DSDL2IMAGE_JPG_SAVE=yes \
	-DSDL2IMAGE_PNG_SAVE=yes \
	-DSDL2IMAGE_PNG_SHARED=no \
	-DSDL2IMAGE_JPG_SHARED=no \
	-DSDL2IMAGE_JXL=no \
	-DSDL2IMAGE_BACKEND_IMAGEIO=no \
	-DSDL2IMAGE_VENDORED=yes


# SDL_sound (submodule: sources/sdl_sound)
sdlsound: init_dirs sdl2 libogg libvorbis $(LIBDIR)/libSDL2_sound.a

$(LIBDIR)/libSDL2_sound.a: $(SOURCES)/sdl_sound/$(CMAKE_BUILDDIR)/Makefile
	cd $(SOURCES)/sdl_sound/$(CMAKE_BUILDDIR); \
	make -j$(NPROC); make install

$(SOURCES)/sdl_sound/$(CMAKE_BUILDDIR)/Makefile: $(SOURCES)/sdl_sound/CMakeLists.txt
	cd $(SOURCES)/sdl_sound; mkdir -p $(CMAKE_BUILDDIR); cd $(CMAKE_BUILDDIR); \
	$(CMAKE) \
	-DSDLSOUND_BUILD_SHARED=false \
	-DSDLSOUND_BUILD_TEST=false \
	-DSDLSOUND_DECODER_COREAUDIO=false


# SDL2_ttf (submodule: sources/sdl2_ttf)
sdl2ttf: init_dirs sdl2 freetype $(LIBDIR)/libSDL2_ttf.a

$(LIBDIR)/libSDL2_ttf.a: $(SOURCES)/sdl2_ttf/.configured-$(SDK_TAG)
	cd $(SOURCES)/sdl2_ttf; \
	make -j$(NPROC) lib; make install-libLTLIBRARIES install-libSDL2_ttfincludeHEADERS install-pkgconfigDATA

$(SOURCES)/sdl2_ttf/.configured-$(SDK_TAG): $(SOURCES)/sdl2_ttf/configure
	cd $(SOURCES)/sdl2_ttf; $(MAKE) distclean 2>/dev/null || true
	cd $(SOURCES)/sdl2_ttf; \
	$(CONFIGURE) --enable-static=true --enable-shared=false
	touch $@

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

$(LIBDIR)/libopenal.a: $(SOURCES)/openal-soft/$(CMAKE_BUILDDIR)/Makefile
	cd $(SOURCES)/openal-soft/$(CMAKE_BUILDDIR); \
	make -j$(NPROC); make install

$(SOURCES)/openal-soft/$(CMAKE_BUILDDIR)/Makefile: $(SOURCES)/openal-soft/CMakeLists.txt
	cd $(SOURCES)/openal-soft; \
	mkdir -p $(CMAKE_BUILDDIR); cd $(CMAKE_BUILDDIR); \
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


# OpenSSL 1.1.x (static) — linked by Empo via -lssl -lcrypto in project.yml.
# Ruby's openssl ext is merged into mkxp31-merged.o; the app also links these
# archives directly. Pin 1.1.1w to match the previously hand-built libs.
OPENSSL_VERSION := 1.1.1w
OPENSSL_DIR := $(DOWNLOADS)/openssl-$(OPENSSL_VERSION)
OPENSSL_CONFIGURE_TARGET := ios64-xcrun
ifeq ($(SDK),iphonesimulator)
OPENSSL_CONFIGURE_TARGET := iossimulator-xcrun
endif
OPENSSL_CONFIGURED := $(OPENSSL_DIR)/.configured-$(SDK)-$(ARCH)

openssl: init_dirs $(LIBDIR)/libcrypto.a $(LIBDIR)/libssl.a

$(LIBDIR)/libcrypto.a $(LIBDIR)/libssl.a: $(BUILD_PREFIX)/.openssl-installed

$(BUILD_PREFIX)/.openssl-installed: $(OPENSSL_CONFIGURED)
	cd $(OPENSSL_DIR); \
	$(MAKE) -j$(NPROC); \
	$(MAKE) install_sw
	touch $@

$(OPENSSL_CONFIGURED): $(OPENSSL_DIR)/Configure
	cd $(OPENSSL_DIR); $(MAKE) distclean 2>/dev/null || true
	cd $(OPENSSL_DIR); \
	./Configure $(OPENSSL_CONFIGURE_TARGET) no-shared no-dso \
		--prefix="$(BUILD_PREFIX)" \
		--openssldir="$(BUILD_PREFIX)/ssl" \
		$(TARGET_FLAG)
	touch $@

$(OPENSSL_DIR)/Configure: $(DOWNLOADS)/openssl-$(OPENSSL_VERSION).tar.gz
	cd $(DOWNLOADS) && tar xzf openssl-$(OPENSSL_VERSION).tar.gz

$(DOWNLOADS)/openssl-$(OPENSSL_VERSION).tar.gz:
	@mkdir -p $(DOWNLOADS)
	curl -L -o $@ https://github.com/openssl/openssl/releases/download/OpenSSL_1_1_1w/openssl-$(OPENSSL_VERSION).tar.gz


# Freetype (submodule: sources/freetype)
freetype: init_dirs $(LIBDIR)/libfreetype.a

$(LIBDIR)/libfreetype.a: $(SOURCES)/freetype/.configured-$(SDK_TAG)
	cd $(SOURCES)/freetype; \
	make -j$(NPROC); make install

$(SOURCES)/freetype/.configured-$(SDK_TAG): $(SOURCES)/freetype/builds/unix/configure
	cd $(SOURCES)/freetype; $(MAKE) distclean 2>/dev/null || true
	cd $(SOURCES)/freetype; \
	$(CONFIGURE) --enable-static=true --enable-shared=false
	touch $@

$(SOURCES)/freetype/builds/unix/configure: $(SOURCES)/freetype/autogen.sh
	cd $(SOURCES)/freetype; ./autogen.sh

# Ruby 3.1 (submodule: sources/ruby)
ruby: init_dirs openssl $(LIBDIR)/libruby.3.1-static.a $(LIBDIR)/libruby.3.1-ext.a

$(LIBDIR)/libruby.3.1-static.a: $(SOURCES)/ruby/.configured-$(SDK_TAG)
	cd $(SOURCES)/ruby; \
	$(CONFIGURE_ENV) make -j$(NPROC) libruby.3.1-static.a; \
	cp libruby.3.1-static.a $(LIBDIR)/; \
	mkdir -p $(INCLUDEDIR)/ruby31; \
	cp -R include/* $(INCLUDEDIR)/ruby31/; \
	cp .ext/include/*/ruby/config.h $(INCLUDEDIR)/ruby31/ruby/config.h 2>/dev/null || true
	@# Header isolation: 3.1 lives under $(INCLUDEDIR)/ruby31/,
	@# 1.9 under $(INCLUDEDIR)/ruby19/, 1.8 under
	@# $(INCLUDEDIR)/ruby18/. Consumers (project.yml's
	@# HEADER_SEARCH_PATHS, the per-version mkxp{N}-merged make
	@# targets) must point at the right subdir for the version
	@# they want. No global $(INCLUDEDIR)/ruby.h fallback so each
	@# build sees only its own headers.

# Build Ruby 3.1 extensions (zlib, stringio, strscan, digest, etc.) plus
# encoding libs into libruby.3.1-ext.a. Mirrors the Ruby 1.8 pattern (see
# RUBY18_EXTS above). ext/extinit.o and enc/encinit.o replace the dmyext.o
# and dmyenc.o stubs that live in libruby.3.1-static.a.
#
# `miniruby` is the host-side Ruby executable that runs the
# extconf scripts and generates the encoding bundles. Ruby's
# default targets don't build miniruby unless asked: a bare
# `make libruby.3.1-static.a` skips it, so a clean rebuild here
# silently produced an empty ext.a (zlib, stringio, etc. all
# missing) which then linked into mkxp31-merged.o, leaving
# scripts.rxdata decoding broken at runtime. Force-build miniruby
# before exts so cross-compile bundle linking can find it.
$(LIBDIR)/libruby.3.1-ext.a: $(LIBDIR)/libruby.3.1-static.a
	cd $(SOURCES)/ruby; \
	$(CONFIGURE_ENV) make -j1 miniruby exts.mk encs; \
	EXT_TARGETS=$$(sed -n '9,18p' exts.mk | tr '\\' ' ' | grep -oE 'ext/[^ ]+' | sed 's|/\.$$|/static|'); \
	$(CONFIGURE_ENV) make -j1 -f exts.mk ext/extinit.o $$EXT_TARGETS; \
	$(CONFIGURE_ENV) make -j1 enc/encinit.o
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

$(SOURCES)/ruby/.configured-$(SDK_TAG): $(SOURCES)/ruby/configure $(LIBDIR)/libcrypto.a
	cd $(SOURCES)/ruby; $(MAKE) distclean 2>/dev/null || true
	cd $(SOURCES)/ruby; \
	export $(CONFIGURE_ENV); \
	export CFLAGS="-std=gnu99 -DRUBY_FUNCTION_NAME_STRING=__func__ $$CFLAGS"; \
	export LDFLAGS="$$LDFLAGS"; \
	./configure $(CONFIGURE_ARGS) $(RUBY_CONFIGURE_ARGS) \
	--with-baseruby=/usr/bin/ruby \
	--with-openssl-dir="$(BUILD_PREFIX)" \
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
	touch $@

$(SOURCES)/ruby/configure: $(SOURCES)/ruby/configure.ac
	cd $(SOURCES)/ruby; \
	git checkout -- . 2>/dev/null; \
	$(PATCHES)/apply-ruby-patches.sh 31 $(SOURCES)/ruby \
		--patches-root $(PATCHES) --engine $(ENGINE); \
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
# This target builds the per-version mkxp-z merged objects for
# Ruby 1.8 / 1.9 / 3.1. Native Ruby 3.0 was dropped: the syntax-
# transform parser patches only exist in the 3.1 source, so 3.0 +
# Legacy compatibility was a silent no-op that confused users on
# Pokemon Essentials forks. Auto-detect routes 3.0-bundling games
# to 3.1 + Legacy.

# Suppress the same warnings project.yml suppresses, so the per-Ruby
# binding compile is no noisier than the in-Xcode build.
MKXPZ_WARNFLAGS := \
    -Wno-documentation -Wno-shorten-64-to-32 -Wno-deprecated-declarations \
    -Wno-uninitialized -Wno-conditional-uninitialized -Wno-undefined-var-template \
    -Wno-comma -Wno-switch -Wno-unused-const-variable \
    -Wno-deprecated-literal-operator -Wno-unused-function

mkxp31-merged: init_dirs ruby     $(LIBDIR)/mkxp31-merged.o
mkxp19-merged: init_dirs ruby19   $(LIBDIR)/mkxp19-merged.o
mkxp18-merged: init_dirs ruby18   $(LIBDIR)/mkxp18-merged.o
mkxp-merged: mkxp18-merged mkxp19-merged mkxp31-merged

# Ruby 3.1 — patched parser with syntax-transform support. Includes
# are
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
	    | grep -vE '^__Z(TI|TS|TV)|^___cxa_' \
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
	    | grep -vE '^__Z(TI|TS|TV)|^___cxa_' \
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
	    | grep -vE '^__Z(TI|TS|TV)|^___cxa_' \
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
ruby18: init_dirs $(LIBDIR)/libruby18-static.a $(LIBDIR)/libruby18-ext.a

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
ruby19: init_dirs $(LIBDIR)/libruby19-static.a $(LIBDIR)/libruby19-ext.a

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

$(LIBDIR)/libruby19-static.a: $(SOURCES)/ruby19/.configured-$(SDK_TAG)
	cd $(SOURCES)/ruby19; \
	$(CONFIGURE_ENV) make -j$(NPROC) libruby-static.a; \
	cp libruby-static.a $(LIBDIR)/libruby19-static.a; \
	mkdir -p $(INCLUDEDIR)/ruby19; \
	cp -R include/* $(INCLUDEDIR)/ruby19/; \
	cp .ext/include/aarch64-darwin/ruby/config.h $(INCLUDEDIR)/ruby19/ruby/config.h 2>/dev/null || true
	@# Compile our setjmp/longjmp shim and inject it into
	@# libruby19-static.a. The shim is currently a tail-call
	@# forwarder to libc _setjmp / _longjmp; we keep the
	@# indirection so we can swap the implementation per-arch
	@# without rebuilding the rest of Ruby. config.h is sed'd
	@# in the Makefile rule below to point RUBY_SETJMP /
	@# RUBY_LONGJMP at our symbols.
	$(CC) $(TARGETFLAGS) -c ${PWD}/ruby19/mkxp_setjmp_arm64.S \
		-o $(SOURCES)/ruby19/mkxp_setjmp_arm64.o
	$(AR) rcs $(LIBDIR)/libruby19-static.a $(SOURCES)/ruby19/mkxp_setjmp_arm64.o
	$(RANLIB) $(LIBDIR)/libruby19-static.a
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

$(SOURCES)/ruby19/.configured-$(SDK_TAG): $(SOURCES)/ruby19/configure
	cd $(SOURCES)/ruby19; $(MAKE) distclean 2>/dev/null || true
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
	@# Override config.h's RUBY_SETJMP / RUBY_LONGJMP to point at
	@# our shim symbols (see mkxp_setjmp_arm64.S). The shim
	@# currently tail-calls libc _setjmp / _longjmp; the
	@# indirection lets us swap implementations per-arch
	@# without rebuilding the rest of Ruby. `returns_twice`
	@# tells the compiler the call may resume control flow at
	@# the call site so locals stay reload-safe.
	CONFIG_H=$(SOURCES)/ruby19/.ext/include/aarch64-darwin/ruby/config.h; \
	if [ -f $$CONFIG_H ]; then \
	    sed -i '' \
	        -e 's|^#define RUBY_SETJMP(env) _setjmp(env)$$|#define RUBY_SETJMP(env) mkxp_ruby19_setjmp(env)|' \
	        -e 's|^#define RUBY_LONGJMP(env,val) _longjmp(env,val)$$|#define RUBY_LONGJMP(env,val) mkxp_ruby19_longjmp(env,val)|' \
	        $$CONFIG_H; \
	    echo '' >> $$CONFIG_H; \
	    echo 'extern int  mkxp_ruby19_setjmp(void *env) __attribute__((returns_twice));' >> $$CONFIG_H; \
	    echo 'extern void mkxp_ruby19_longjmp(void *env, int val) __attribute__((noreturn));' >> $$CONFIG_H; \
	fi
	touch $@

$(SOURCES)/ruby19/configure: $(SOURCES)/ruby19/configure.in
	cd $(SOURCES)/ruby19; \
	git checkout -- . 2>/dev/null; \
	git clean -fdxq 2>/dev/null; \
	rm -f aarch64-darwin-fake.rb arm64-darwin-fake.rb; \
	$(PATCHES)/apply-ruby-patches.sh 19 $(SOURCES)/ruby19 \
		--patches-root $(PATCHES) --engine $(ENGINE); \
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

$(LIBDIR)/libruby18-static.a: $(SOURCES)/ruby18/.configured-$(SDK_TAG)
	set -e; \
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

$(SOURCES)/ruby18/.configured-$(SDK_TAG): $(SOURCES)/ruby18/configure
	cd $(SOURCES)/ruby18; $(MAKE) distclean 2>/dev/null || true
	cd $(SOURCES)/ruby18; \
	$(CONFIGURE_ENV) CFLAGS="$(RUBY18_CFLAGS)" \
	./configure \
		--host=$(HOST) \
		--build=x86_64-apple-darwin \
		--prefix="$(BUILD_PREFIX)" \
		--disable-shared \
		--enable-static \
		--with-static-linked-ext; \
	sed -i '' 's|^MINIRUBY = ruby |MINIRUBY = ruby --disable=gems |' $(SOURCES)/ruby18/Makefile; \
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
	touch $@

$(SOURCES)/ruby18/configure: $(SOURCES)/ruby18/configure.in
	cd $(SOURCES)/ruby18; \
	git checkout -- . 2>/dev/null; \
	git clean -fdx 2>/dev/null; \
	$(PATCHES)/apply-ruby-patches.sh 18 $(SOURCES)/ruby18 \
		--patches-root $(PATCHES) --engine $(ENGINE); \
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
	@for dir in sdl2 sdl2_image sdl2_ttf sdl_sound freetype ruby ruby18 ruby19 openal-soft; do \
		rm -rf $(SOURCES)/$$dir/$(CMAKE_BUILDDIR) 2>/dev/null; \
		rm -f $(SOURCES)/$$dir/.configured-* 2>/dev/null; \
	done
	@for dir in ogg vorbis theora pixman libpng uchardet physfs; do \
		rm -rf $(DOWNLOADS)/$$dir/$(CMAKE_BUILDDIR) 2>/dev/null; \
		rm -f $(DOWNLOADS)/$$dir/.configured-* 2>/dev/null; \
	done
	cd $(SOURCES)/sdl2_ttf && git checkout -- . 2>/dev/null || true
	cd $(SOURCES)/freetype && git checkout -- . 2>/dev/null || true
	cd $(SOURCES)/ruby && git checkout -- . 2>/dev/null || true
	cd $(SOURCES)/ruby18 && git checkout -- . 2>/dev/null || true
	cd $(SOURCES)/ruby19 && git checkout -- . 2>/dev/null || true

deps-core: libtheora libvorbis pixman libpng physfs uchardet sdl2 sdl2image sdlsound sdl2ttf freetype openal openssl
everything: deps-core ruby ruby18
