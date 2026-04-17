/*
** movie.cpp
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

#include "movie.h"

#include "al-util.h"
#include "audio.h"
#include "bitmap.h"
#include "debugwriter.h"
#include "graphics.h"
#include "input.h"
#include "sharedstate.h"

#include <SDL.h>
#include <climits>

static long readMovie(THEORAPLAY_Io *io, void *buf, long buflen)
{
    SDL_RWops *f = (SDL_RWops *) io->userdata;
    return (long) SDL_RWread(f, buf, 1, buflen);
}

static void closeMovie(THEORAPLAY_Io *io)
{
    SDL_RWops *f = (SDL_RWops *) io->userdata;
    SDL_RWclose(f);
    free(io);
}

Movie::Movie(bool skippable_)
: decoder(0), audio(0), video(0), skippable(skippable_), videoBitmap(0), audioThread(0)
{
}

Movie::~Movie()
{
    if (hasAudio) {
        if (audioQueueTail) {
            THEORAPLAY_freeAudio(audioQueueTail->audio);
        }
        audioQueueTail = NULL;

        if (audioQueueHead) {
            THEORAPLAY_freeAudio(audioQueueHead->audio);
        }
        audioQueueHead = NULL;
        SDL_DestroyMutex(audioMutex);
        audioThreadTermReq.set();
        if(audioThread) {
            SDL_WaitThread(audioThread, 0);
            audioThread = 0;
        }
        alSourceStop(audioSource);
        alDeleteSources(1, &audioSource);
        alDeleteBuffers(STREAM_BUFS, alBuffers);
    }
    if (video) THEORAPLAY_freeVideo(video);
    if (audio) THEORAPLAY_freeAudio(audio);
    if (decoder) THEORAPLAY_stopDecode(decoder);
    delete videoBitmap;
}

// Safety net for preparePlayback() spin loops: if the file is not a
// valid Ogg Theora stream, prepped/video/audio will never come, and
// the Ruby thread hangs in C land where checkShutdown() can't run.
// We bail after PREP_TIMEOUT_MS and also yield promptly to a pending
// termination or reset request.
static const Uint32 PREP_TIMEOUT_MS = 5000;

static bool prepShouldAbort(Uint32 startTicks)
{
    // Giving up the Ruby thread back to the main thread is handled by
    // the main thread's rqTerm/rqReset flags. If either is set, abort
    // the decode init so Graphics.play_movie returns and the next
    // checkShutdown()/checkReset() can unwind the script.
    if (shState && shState->graphics().updateMovieInput(nullptr)) {
        return true;
    }
    return (SDL_GetTicks() - startTicks) >= PREP_TIMEOUT_MS;
}

bool Movie::preparePlayback()
{
    THEORAPLAY_Io *io = (THEORAPLAY_Io *) malloc(sizeof (THEORAPLAY_Io));
    if(!io) {
        SDL_RWclose(&srcOps);
        return false;
    }

    io->read = readMovie;
    io->close = closeMovie;
    io->userdata = &srcOps;
    decoder = THEORAPLAY_startDecode(io, DEF_MAX_VIDEO_FRAMES, THEORAPLAY_VIDFMT_RGBA);
    if (!decoder) {
        SDL_RWclose(&srcOps);
        return false;
    }

    const Uint32 prepStart = SDL_GetTicks();

    while (!THEORAPLAY_isInitialized(decoder)) {
        if (prepShouldAbort(prepStart)) {
            Debug() << "Movie: giving up on decoder init (bad file or terminate)";
            THEORAPLAY_stopDecode(decoder);
            decoder = nullptr;
            return false;
        }
        SDL_Delay(VIDEO_DELAY);
    }

    hasAudio = THEORAPLAY_hasAudioStream(decoder);
    hasVideo = THEORAPLAY_hasVideoStream(decoder);

    if (hasAudio) {
        while ((audio = THEORAPLAY_getAudio(decoder)) == NULL) {
            if ((THEORAPLAY_availableVideo(decoder) >= DEF_MAX_VIDEO_FRAMES)) {
                break;
            }
            if (prepShouldAbort(prepStart)) break;
            SDL_Delay(VIDEO_DELAY);
        }
    }

    if (!hasVideo) {
        THEORAPLAY_stopDecode(decoder);
        return false;
    }

    while ((video = THEORAPLAY_getVideo(decoder)) == NULL) {
        if (prepShouldAbort(prepStart)) {
            THEORAPLAY_stopDecode(decoder);
            decoder = nullptr;
            return false;
        }
        SDL_Delay(VIDEO_DELAY);
    }

    audio = NULL;
    if (hasAudio) {
        while ((audio = THEORAPLAY_getAudio(decoder)) == NULL && THEORAPLAY_availableVideo(decoder) < DEF_MAX_VIDEO_FRAMES) {
            if (prepShouldAbort(prepStart)) break;
            SDL_Delay(VIDEO_DELAY);
        }
    }

    videoBitmap = new Bitmap(video->width, video->height, true);
    audioQueueHead = NULL;
    audioQueueTail = NULL;

    return true;
}

void Movie::queueAudioPacket(const THEORAPLAY_AudioPacket *audio) {
    AudioQueue *item = NULL;

    if (!audio) {
        return;
    }

    item = (AudioQueue *) malloc(sizeof (AudioQueue));
    if (!item) {
        THEORAPLAY_freeAudio(audio);
        return;
    }

    item->audio = audio;
    item->offset = 0;
    item->next = NULL;

    SDL_LockMutex(audioMutex);
    if (audioQueueTail) {
        audioQueueTail->next = item;
    } else {
        audioQueueHead = item;
    }
    audioQueueTail = item;
    SDL_UnlockMutex(audioMutex);
}

void Movie::bufferMovieAudio(THEORAPLAY_Decoder *decoder, const Uint32 now) {
    const THEORAPLAY_AudioPacket *audio;
    while ((audio = THEORAPLAY_getAudio(decoder)) != NULL) {
        queueAudioPacket(audio);
        if (audio->playms >= now + AUDIO_BUFFER_LEN_MS) {
            break;
        }
    }
}

void Movie::streamMovieAudio(){
    ALint state = 0;
    ALint procBufs = STREAM_BUFS;
    volatile AudioQueue *audioPacketAndOffset;
    int channels;
    int sampleRate;
    float *sourceSamples;
    ALuint samplesToProcess;
    ALshort *sampleBuffer;
    ALuint remainingSamples;

    while(true) {
        while(procBufs--) {
            if (audioThreadTermReq) return;

            remainingSamples = MOVIE_AUDIO_BUFFER_SIZE;
            sampleBuffer = audioBuffer;
            SDL_LockMutex(audioMutex);

            while(audioQueueHead && (remainingSamples > 0)) {
                audioPacketAndOffset = audioQueueHead;
                channels = audioPacketAndOffset->audio->channels;
                sampleRate = audioPacketAndOffset->audio->freq;
                sourceSamples = audioPacketAndOffset->audio->samples + (audioPacketAndOffset->offset * channels);
                samplesToProcess = (audioPacketAndOffset->audio->frames - audioPacketAndOffset->offset) * channels;

                if (samplesToProcess > remainingSamples) samplesToProcess = remainingSamples;

                for (ALuint i = 0; i < samplesToProcess; i++) {
                    const float val = (*(sourceSamples++));
                    if (val < -1.0f) {
                        *(sampleBuffer++) = SHRT_MIN;
                    } else if (val > 1.0f) {
                        *(sampleBuffer++) = SHRT_MAX;
                    } else {
                        *(sampleBuffer++) = (ALshort) (val * SHRT_MAX);
                    }
                }

                audioPacketAndOffset->offset += (samplesToProcess / channels);
                remainingSamples -= samplesToProcess;

                if ((audioPacketAndOffset->offset) >= audioPacketAndOffset->audio->frames) {
                    audioQueueHead = audioPacketAndOffset->next;
                    THEORAPLAY_freeAudio(audioPacketAndOffset->audio);
                    free((void *) audioPacketAndOffset);
                }
            }

            if(!audioQueueHead) audioQueueTail = NULL;

            SDL_UnlockMutex(audioMutex);

            alBufferData(alBuffers[procBufs], channels == 1 ? AL_FORMAT_MONO16 : AL_FORMAT_STEREO16, audioBuffer,
                (MOVIE_AUDIO_BUFFER_SIZE - remainingSamples) * sizeof(ALshort), sampleRate);
            alSourceQueueBuffers(audioSource, 1, &alBuffers[procBufs]);
            alGetSourcei(audioSource, AL_SOURCE_STATE, &state);
            if(state != AL_PLAYING) alSourcePlay(audioSource);
        }

        while(true) {
            if (audioThreadTermReq) return;

            alGetSourcei(audioSource, AL_BUFFERS_PROCESSED, &procBufs);
            if(procBufs > 0) break;
            SDL_Delay(AUDIO_SLEEP);
        }
        alSourceUnqueueBuffers(audioSource, procBufs, alBuffers);
    }
}

bool Movie::startAudio(float volume)
{
    alGenSources(1, &audioSource);
    alGenBuffers(STREAM_BUFS, alBuffers);
    alSourcef(audioSource, AL_GAIN, volume);

    audioThreadTermReq.clear();
    audioMutex = SDL_CreateMutex();
    queueAudioPacket(audio);
    audio = NULL;
    bufferMovieAudio(decoder, 0);
    audioThread = createSDLThread <Movie, &Movie::streamMovieAudio>(this, "movieaudio");

    return true;
}

void Movie::play(float volume)
{
    Uint32 frameMs = 0;
    Uint32 baseTicks = SDL_GetTicks();
    bool openedAudio = false;
    while (THEORAPLAY_isDecoding(decoder)) {
        if(shState->graphics().updateMovieInput(this)) break;

        if (skippable) {
            shState->input().update();
            if  (shState->input().isTriggered(Input::C) || shState->input().isTriggered(Input::B)) break;
        }

        const Uint32 now = SDL_GetTicks() - baseTicks;

        if (!video) {
            video = THEORAPLAY_getVideo(decoder);
        }

        if (hasAudio) {
            if (!audio) {
                audio = THEORAPLAY_getAudio(decoder);
            }

            if (audio && !openedAudio) {
                if(!startAudio(volume)){
                    Debug() << "Error opening movie audio!";
                    break;
                }
                openedAudio = true;
            }

        }

        if (video && (video->playms <= now)) {
            frameMs = (video->fps == 0.0) ? 0 : ((Uint32) (1000.0 / video->fps));
            if ( frameMs && ((now - video->playms) >= frameMs) )
            {
                const THEORAPLAY_VideoFrame *last = video;
                while ((video = THEORAPLAY_getVideo(decoder)) != NULL)
                {
                    THEORAPLAY_freeVideo(last);
                    last = video;
                    if ((now - video->playms) < frameMs)
                        break;
                }

                if (!video)
                    video = last;
            }

            if (!video) {
                Debug() << "WARNING: Video playback cannot keep up!";
                break;
            }

            videoBitmap->replaceRaw(video->pixels, video->width * video->height * 4);
            shState->graphics().update(false);
            THEORAPLAY_freeVideo(video);
            video = NULL;

        } else {
            SDL_Delay(VIDEO_DELAY);
        }

        if (openedAudio) {
            bufferMovieAudio(decoder, now);
        }
    }
}
