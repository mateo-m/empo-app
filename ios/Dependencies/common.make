SYSROOT := $(shell xcrun --sdk $(SDK) --show-sdk-path)
TARGETFLAGS := -isysroot $(SYSROOT) $(TARGET_FLAG) -arch $(ARCH)
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
	cp -R include/* $(INCLUDEDIR)/; \
	cp .ext/include/*/ruby/config.h $(INCLUDEDIR)/ruby/config.h 2>/dev/null || true

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

# Ruby 1.8 (submodule: sources/ruby18)
ruby18: init_dirs $(LIBDIR)/libruby18-static.a

RUBY18_CFLAGS = $(TARGETFLAGS) -std=gnu89 -O2 \
	-Wno-implicit-function-declaration \
	-Wno-implicit-int \
	-Wno-incompatible-pointer-types \
	-Wno-int-conversion \
	-Wno-deprecated-non-prototype \
	-Wno-incompatible-function-pointer-types

RUBY18_EXTS = zlib stringio strscan thread digest fcntl

$(LIBDIR)/libruby18-static.a: $(SOURCES)/ruby18/Makefile
	cd $(SOURCES)/ruby18; \
	$(CONFIGURE_ENV) CFLAGS="$(RUBY18_CFLAGS)" make -j$(NPROC) COMPILE_PRELUDE=true libruby-static.a; \
	cp libruby-static.a $(LIBDIR)/libruby18-static.a; \
	mkdir -p $(INCLUDEDIR)/ruby18; \
	cp *.h $(INCLUDEDIR)/ruby18/
	@# Build extensions (use Ruby 1.8 headers only, not $(INCLUDEDIR) which has Ruby 3.1)
	@EXTCFLAGS="$(RUBY18_CFLAGS) -I$(SOURCES)/ruby18 -I$(SOURCES)/ruby18/include -I$(INCLUDEDIR)"; \
	OBJ_FILES=""; \
	for ext in $(RUBY18_EXTS); do \
		for src in $(SOURCES)/ruby18/ext/$$ext/*.c; do \
			obj=$${src%.c}.o; \
			$(CC) $$EXTCFLAGS -c $$src -o $$obj; \
			OBJ_FILES="$$OBJ_FILES $$obj"; \
		done; \
	done; \
	$(AR) rcs $(LIBDIR)/libruby18-ext.a $$OBJ_FILES; \
	$(RANLIB) $(LIBDIR)/libruby18-ext.a

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
