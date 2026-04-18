/*
** movie.h
**
** This file is part of mkxp.
**
** Copyright (C) 2013 - 2021 Amaryllis Kulla <ancurio@mapleshrine.eu>
**
** mkxp is free software: you can redistribute it and/or modify
** it under the terms of the GNU General Public License as published by
** the Free Software Foundation, either version 2 of the License, or
** (at your option) any later version.
**
** mkxp is distributed in the hope that it will be useful,
** but WITHOUT ANY WARRANTY; without even the implied warranty of
** MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
** GNU General Public License for more details.
**
** You should have received a copy of the GNU General Public License
** along with mkxp.  If not, see <http://www.gnu.org/licenses/>.
*/

#ifndef MOVIE_H
#define MOVIE_H

#include "util.h"
#include "sdl-util.h"
#include "alstream.h"
#include "filesystem.h"
#include "theoraplay/theoraplay.h"

#include <SDL.h>
#include <SDL_thread.h>
#include <SDL_mutex.h>

class Bitmap;

#define DEF_MAX_VIDEO_FRAMES 30
#define VIDEO_DELAY 10
#define MOVIE_AUDIO_BUFFER_SIZE 2048
#define AUDIO_BUFFER_LEN_MS 2000

typedef struct AudioQueue
{
    const THEORAPLAY_AudioPacket *audio;
    int offset;
    struct AudioQueue *next;
} AudioQueue;

struct MovieOpenHandler : FileSystem::OpenHandler
{
    SDL_RWops *srcOps;

    MovieOpenHandler(SDL_RWops &srcOps)
    :   srcOps(&srcOps)
    {}

    bool tryRead(SDL_RWops &ops, const char *ext)
    {
        *srcOps = ops;
        return true;
    }
};

struct Movie
{
    // Default member initializers so every field has a defined value
    // even on error paths where preparePlayback() returns before
    // touching them. The destructor reads hasAudio / audioMutex /
    // audioQueue{Head,Tail} / audioSource / alBuffers unconditionally;
    // if any were uninitialized, aborting on a bad movie file would
    // produce UB (dereferencing garbage pointers or freeing bogus
    // AL handles). See preparePlayback() early-abort paths.
    THEORAPLAY_Decoder *decoder = nullptr;
    const THEORAPLAY_AudioPacket *audio = nullptr;
    const THEORAPLAY_VideoFrame *video = nullptr;
    bool hasVideo = false;
    bool hasAudio = false;
    bool skippable = false;
    Bitmap *videoBitmap = nullptr;
    SDL_RWops srcOps{};
    SDL_Thread *audioThread = nullptr;
    AtomicFlag audioThreadTermReq;
    volatile AudioQueue *audioQueueHead = nullptr;
    volatile AudioQueue *audioQueueTail = nullptr;
    ALuint audioSource = 0;
    ALuint alBuffers[STREAM_BUFS]{};
    ALshort audioBuffer[MOVIE_AUDIO_BUFFER_SIZE]{};
    SDL_mutex *audioMutex = nullptr;

    Movie(bool skippable_);
    ~Movie();

    bool preparePlayback();
    void play(float volume);

private:
    void queueAudioPacket(const THEORAPLAY_AudioPacket *audio);
    void bufferMovieAudio(THEORAPLAY_Decoder *decoder, const Uint32 now);
    void streamMovieAudio();
    bool startAudio(float volume);
};

#endif // MOVIE_H
