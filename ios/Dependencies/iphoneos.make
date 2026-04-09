ARCH := arm64
HOST := aarch64-apple-darwin
SDK := iphoneos
MINIMUM_REQUIRED := 26.0
TARGET_FLAG := -miphoneos-version-min=$(MINIMUM_REQUIRED)

include common.make
