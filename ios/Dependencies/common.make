SYSROOT := $(shell xcrun --sdk $(SDK) --show-sdk-path)
TARGETFLAGS := -isysroot $(SYSROOT) $(TARGET_FLAG) -arch $(ARCH)
BUILD_PREFIX := ${PWD}/build-$(SDK)-$(ARCH)
LIBDIR := $(BUILD_PREFIX)/lib
INCLUDEDIR := $(BUILD_PREFIX)/include
DOWNLOADS := ${PWD}/downloads/$(HOST)
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

# SDL2
sdl2: init_dirs $(LIBDIR)/libSDL2.a

$(LIBDIR)/libSDL2.a: $(DOWNLOADS)/sdl2/cmakebuild/Makefile
	cd $(DOWNLOADS)/sdl2/cmakebuild; \
	make -j$(NPROC); make install

$(DOWNLOADS)/sdl2/cmakebuild/Makefile: $(DOWNLOADS)/sdl2/CMakeLists.txt
	cd $(DOWNLOADS)/sdl2; \
	mkdir -p cmakebuild; cd cmakebuild; \
	$(CMAKE) -DBUILD_SHARED_LIBS=no \
	-DSDL_OPENGL=OFF \
	-DSDL_OPENGLES=ON \
	-DSDL_METAL=ON \
	-DSDL_RENDER_METAL=ON

$(DOWNLOADS)/sdl2/CMakeLists.txt:
	$(CLONE) $(GITHUB)/mkxp-z/SDL $(DOWNLOADS)/sdl2 -b mkxp-z-2.28.1

# SDL_image
sdl2image: init_dirs sdl2 $(LIBDIR)/libSDL2_image.a

$(LIBDIR)/libSDL2_image.a: $(DOWNLOADS)/sdl2_image/cmakebuild/Makefile
	cd $(DOWNLOADS)/sdl2_image/cmakebuild; \
	make -j$(NPROC); make install

$(DOWNLOADS)/sdl2_image/cmakebuild/Makefile: $(DOWNLOADS)/sdl2_image/CMakeLists.txt
	cd $(DOWNLOADS)/sdl2_image; mkdir -p cmakebuild; cd cmakebuild; \
	$(CMAKE) \
	-DBUILD_SHARED_LIBS=no \
	-DSDL2IMAGE_JPG_SAVE=yes \
	-DSDL2IMAGE_PNG_SAVE=yes \
	-DSDL2IMAGE_PNG_SHARED=no \
	-DSDL2IMAGE_JPG_SHARED=no \
	-DSDL2IMAGE_JXL=no \
	-DSDL2IMAGE_BACKEND_IMAGEIO=no \
	-DSDL2IMAGE_VENDORED=yes


$(DOWNLOADS)/sdl2_image/CMakeLists.txt:
	$(CLONE) $(GITHUB)/mkxp-z/SDL_image $(DOWNLOADS)/sdl2_image -b mkxp-z; \
	cd $(DOWNLOADS)/sdl2_image; \
	./external/download.sh


# SDL_sound
sdlsound: init_dirs sdl2 libogg libvorbis $(LIBDIR)/libSDL2_sound.a

$(LIBDIR)/libSDL2_sound.a: $(DOWNLOADS)/sdl_sound/cmakebuild/Makefile
	cd $(DOWNLOADS)/sdl_sound/cmakebuild; \
	make -j$(NPROC); make install

$(DOWNLOADS)/sdl_sound/cmakebuild/Makefile: $(DOWNLOADS)/sdl_sound/CMakeLists.txt
	cd $(DOWNLOADS)/sdl_sound; mkdir -p cmakebuild; cd cmakebuild; \
	$(CMAKE) \
	-DSDLSOUND_BUILD_SHARED=false \
	-DSDLSOUND_BUILD_TEST=false \
	-DSDLSOUND_DECODER_COREAUDIO=false

$(DOWNLOADS)/sdl_sound/CMakeLists.txt:
	$(CLONE) $(GITHUB)/mkxp-z/SDL_sound $(DOWNLOADS)/sdl_sound -b git


# SDL2 (ttf)
sdl2ttf: init_dirs sdl2 freetype $(LIBDIR)/libSDL2_ttf.a

$(LIBDIR)/libSDL2_ttf.a: $(DOWNLOADS)/sdl2_ttf/Makefile
	cd $(DOWNLOADS)/sdl2_ttf; \
	make -j$(NPROC); make install

$(DOWNLOADS)/sdl2_ttf/Makefile: $(DOWNLOADS)/sdl2_ttf/configure
	cd $(DOWNLOADS)/sdl2_ttf; \
	$(CONFIGURE) --enable-static=true --enable-shared=false

$(DOWNLOADS)/sdl2_ttf/configure: $(DOWNLOADS)/sdl2_ttf/autogen.sh
	cd $(DOWNLOADS)/sdl2_ttf; ./autogen.sh

$(DOWNLOADS)/sdl2_ttf/autogen.sh:
	$(CLONE) $(GITHUB)/mkxp-z/SDL_ttf $(DOWNLOADS)/sdl2_ttf -b mkxp-z

# Freetype
freetype: init_dirs $(LIBDIR)/libfreetype.a

$(LIBDIR)/libfreetype.a: $(DOWNLOADS)/freetype/Makefile
	cd $(DOWNLOADS)/freetype; \
	make -j$(NPROC); make install

$(DOWNLOADS)/freetype/Makefile: $(DOWNLOADS)/freetype/configure
	cd $(DOWNLOADS)/freetype; \
	$(CONFIGURE) --enable-static=true --enable-shared=false

$(DOWNLOADS)/freetype/configure: $(DOWNLOADS)/freetype/autogen.sh
	cd $(DOWNLOADS)/freetype; ./autogen.sh

$(DOWNLOADS)/freetype/autogen.sh:
	$(CLONE) $(GITHUB)/mkxp-z/freetype2 $(DOWNLOADS)/freetype

# Ruby (static only for iOS)
ruby: init_dirs $(LIBDIR)/libruby.3.1-static.a

$(LIBDIR)/libruby.3.1-static.a: $(DOWNLOADS)/ruby/Makefile
	cd $(DOWNLOADS)/ruby; \
	$(CONFIGURE_ENV) make -j$(NPROC) libruby.3.1-static.a; \
	cp libruby.3.1-static.a $(LIBDIR)/; \
	cp -R include/* $(INCLUDEDIR)/; \
	mkdir -p $(INCLUDEDIR)/ruby/internal; \
	cp .ext/include/*/ruby/config.h $(INCLUDEDIR)/ruby/internal/ 2>/dev/null || true

$(DOWNLOADS)/ruby/Makefile: $(DOWNLOADS)/ruby/configure
	cd $(DOWNLOADS)/ruby; \
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
	cross_compiling=yes

$(DOWNLOADS)/ruby/configure: $(DOWNLOADS)/ruby/configure.ac
	cd $(DOWNLOADS)/ruby; autoreconf -i

$(DOWNLOADS)/ruby/configure.ac:
	$(CLONE) $(GITHUB)/mkxp-z/ruby $(DOWNLOADS)/ruby --single-branch -b mkxp-z-3.1.3 --depth 1
	sed -i '' '/: $${PRELOADENV=DYLD_INSERT_LIBRARIES}/g' $(DOWNLOADS)/ruby/configure.ac

# ====
init_dirs:
	@mkdir -p $(LIBDIR) $(INCLUDEDIR)

clean: clean-compiled

powerwash: clean-compiled clean-downloads

clean-downloads:
	-rm -rf downloads/$(HOST)

clean-compiled:
	-rm -rf build-$(SDK)-$(ARCH)

deps-core: libtheora libvorbis pixman libpng physfs uchardet sdl2 sdl2image sdlsound sdl2ttf freetype
everything: deps-core ruby
