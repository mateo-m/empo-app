/* Shim: alext.h - iOS system OpenAL doesn't include extensions */
#ifndef ALEXT_H_STUB
#define ALEXT_H_STUB

/* Float32 format extensions - may not be supported at runtime on iOS */
#ifndef AL_FORMAT_MONO_FLOAT32
#define AL_FORMAT_MONO_FLOAT32 0x10010
#endif
#ifndef AL_FORMAT_STEREO_FLOAT32
#define AL_FORMAT_STEREO_FLOAT32 0x10011
#endif

#endif
