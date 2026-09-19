// SFMLAudio, the Ruby extension PSDK's SFMLAudioDriver calls.
//
// PSDK asks for RubyFmod first and falls back to this. RubyFmod is
// closed source and ships only as a Windows DLL, so on iOS this is the
// only audio driver. Upstream publishes no source for SFMLAudio, so the
// class and method names below come from two places: what the current
// driver calls, in scripts/0 Dependencies/2 Audio/101
// SFMLAudioDriver.rb, and what a released game's own audio code calls.
// Edelweiss Chronicles ships an older audio module that also asks for
// playing? and paused?, which the current driver never uses.

#include "ruby.h"

#include <SFML/Audio.hpp>

namespace {

// sf::Music::openFromMemory keeps the caller's bytes and streams from
// them. It does not copy. The Ruby String that holds the file has to
// outlive the Music, so the wrapper keeps a reference and marks it.
struct MusicBox {
    sf::Music music;
    VALUE memory;
};

// sf::Sound::setBuffer keeps a pointer to the buffer, so the same rule
// applies to the Ruby SoundBuffer object.
struct SoundBox {
    sf::Sound sound;
    VALUE buffer;
};

void musicMark(void *p) {
    rb_gc_mark(static_cast<MusicBox *>(p)->memory);
}

void musicFree(void *p) {
    delete static_cast<MusicBox *>(p);
}

size_t musicSize(const void *) {
    return sizeof(MusicBox);
}

const rb_data_type_t musicType = {
    "SFMLAudio::Music",
    {musicMark, musicFree, musicSize, nullptr},
    nullptr,
    nullptr,
    RUBY_TYPED_FREE_IMMEDIATELY,
};

void soundMark(void *p) {
    rb_gc_mark(static_cast<SoundBox *>(p)->buffer);
}

void soundFree(void *p) {
    delete static_cast<SoundBox *>(p);
}

size_t soundSize(const void *) {
    return sizeof(SoundBox);
}

const rb_data_type_t soundType = {
    "SFMLAudio::Sound",
    {soundMark, soundFree, soundSize, nullptr},
    nullptr,
    nullptr,
    RUBY_TYPED_FREE_IMMEDIATELY,
};

// sf::SoundBuffer::loadFromMemory decodes into its own storage, so this
// one holds no Ruby reference.
void bufferFree(void *p) {
    delete static_cast<sf::SoundBuffer *>(p);
}

size_t bufferSize(const void *) {
    return sizeof(sf::SoundBuffer);
}

const rb_data_type_t bufferType = {
    "SFMLAudio::SoundBuffer",
    {nullptr, bufferFree, bufferSize, nullptr},
    nullptr,
    nullptr,
    RUBY_TYPED_FREE_IMMEDIATELY,
};

MusicBox *getMusic(VALUE self) {
    MusicBox *box = nullptr;
    TypedData_Get_Struct(self, MusicBox, &musicType, box);
    return box;
}

SoundBox *getSound(VALUE self) {
    SoundBox *box = nullptr;
    TypedData_Get_Struct(self, SoundBox, &soundType, box);
    return box;
}

sf::SoundBuffer *getBuffer(VALUE self) {
    sf::SoundBuffer *buffer = nullptr;
    TypedData_Get_Struct(self, sf::SoundBuffer, &bufferType, buffer);
    return buffer;
}

VALUE musicAlloc(VALUE klass) {
    MusicBox *box = new MusicBox();
    box->memory = Qnil;
    return TypedData_Wrap_Struct(klass, &musicType, box);
}

VALUE musicOpenFromMemory(VALUE self, VALUE memory) {
    MusicBox *box = getMusic(self);
    StringValue(memory);
    box->memory = memory;
    bool ok = box->music.openFromMemory(RSTRING_PTR(memory), RSTRING_LEN(memory));
    if (!ok) {
        box->memory = Qnil;
    }
    return ok ? Qtrue : Qfalse;
}

VALUE musicPlay(VALUE self) {
    getMusic(self)->music.play();
    return Qnil;
}

VALUE musicPause(VALUE self) {
    getMusic(self)->music.pause();
    return Qnil;
}

VALUE musicStop(VALUE self) {
    getMusic(self)->music.stop();
    return Qnil;
}

VALUE musicStopped(VALUE self) {
    return getMusic(self)->music.getStatus() == sf::SoundSource::Stopped ? Qtrue : Qfalse;
}

VALUE musicPlaying(VALUE self) {
    return getMusic(self)->music.getStatus() == sf::SoundSource::Playing ? Qtrue : Qfalse;
}

VALUE musicPaused(VALUE self) {
    return getMusic(self)->music.getStatus() == sf::SoundSource::Paused ? Qtrue : Qfalse;
}

VALUE musicSetLoop(VALUE self, VALUE loop) {
    getMusic(self)->music.setLoop(RTEST(loop));
    return loop;
}

VALUE musicSetPitch(VALUE self, VALUE pitch) {
    getMusic(self)->music.setPitch(static_cast<float>(NUM2DBL(pitch)));
    return pitch;
}

VALUE musicSetVolume(VALUE self, VALUE volume) {
    getMusic(self)->music.setVolume(static_cast<float>(NUM2DBL(volume)));
    return volume;
}

VALUE musicGetVolume(VALUE self) {
    return DBL2NUM(getMusic(self)->music.getVolume());
}

VALUE musicGetPlayingOffset(VALUE self) {
    return DBL2NUM(getMusic(self)->music.getPlayingOffset().asSeconds());
}

VALUE musicSetPlayingOffset(VALUE self, VALUE seconds) {
    getMusic(self)->music.setPlayingOffset(sf::seconds(static_cast<float>(NUM2DBL(seconds))));
    return seconds;
}

VALUE musicGetSampleRate(VALUE self) {
    return UINT2NUM(getMusic(self)->music.getSampleRate());
}

VALUE musicGetDuration(VALUE self) {
    return DBL2NUM(getMusic(self)->music.getDuration().asSeconds());
}

VALUE musicSetLoopPoints(VALUE self, VALUE start, VALUE length) {
    sf::Music::TimeSpan span(sf::seconds(static_cast<float>(NUM2DBL(start))),
                             sf::seconds(static_cast<float>(NUM2DBL(length))));
    getMusic(self)->music.setLoopPoints(span);
    return Qnil;
}

VALUE soundAlloc(VALUE klass) {
    SoundBox *box = new SoundBox();
    box->buffer = Qnil;
    return TypedData_Wrap_Struct(klass, &soundType, box);
}

VALUE soundSetBuffer(VALUE self, VALUE buffer) {
    SoundBox *box = getSound(self);
    box->buffer = buffer;
    box->sound.setBuffer(*getBuffer(buffer));
    return buffer;
}

VALUE soundPlay(VALUE self) {
    getSound(self)->sound.play();
    return Qnil;
}

VALUE soundPause(VALUE self) {
    getSound(self)->sound.pause();
    return Qnil;
}

VALUE soundStop(VALUE self) {
    getSound(self)->sound.stop();
    return Qnil;
}

VALUE soundStopped(VALUE self) {
    return getSound(self)->sound.getStatus() == sf::SoundSource::Stopped ? Qtrue : Qfalse;
}

VALUE soundPlaying(VALUE self) {
    return getSound(self)->sound.getStatus() == sf::SoundSource::Playing ? Qtrue : Qfalse;
}

VALUE soundPaused(VALUE self) {
    return getSound(self)->sound.getStatus() == sf::SoundSource::Paused ? Qtrue : Qfalse;
}

VALUE soundSetPitch(VALUE self, VALUE pitch) {
    getSound(self)->sound.setPitch(static_cast<float>(NUM2DBL(pitch)));
    return pitch;
}

VALUE soundSetVolume(VALUE self, VALUE volume) {
    getSound(self)->sound.setVolume(static_cast<float>(NUM2DBL(volume)));
    return volume;
}

VALUE soundGetVolume(VALUE self) {
    return DBL2NUM(getSound(self)->sound.getVolume());
}

VALUE soundGetPlayingOffset(VALUE self) {
    return DBL2NUM(getSound(self)->sound.getPlayingOffset().asSeconds());
}

VALUE soundSetPlayingOffset(VALUE self, VALUE seconds) {
    getSound(self)->sound.setPlayingOffset(sf::seconds(static_cast<float>(NUM2DBL(seconds))));
    return seconds;
}

// The driver reads the rate and the length of a Sound before it sets a
// buffer, and divides by the rate. Answer 0 rather than follow a null
// pointer, and let the driver's own guard take over.
VALUE soundGetSampleRate(VALUE self) {
    const sf::SoundBuffer *buffer = getSound(self)->sound.getBuffer();
    return UINT2NUM(buffer ? buffer->getSampleRate() : 0);
}

VALUE soundGetDuration(VALUE self) {
    const sf::SoundBuffer *buffer = getSound(self)->sound.getBuffer();
    return DBL2NUM(buffer ? buffer->getDuration().asSeconds() : 0.0);
}

VALUE bufferAlloc(VALUE klass) {
    return TypedData_Wrap_Struct(klass, &bufferType, new sf::SoundBuffer());
}

VALUE bufferLoadFromMemory(VALUE self, VALUE memory) {
    StringValue(memory);
    bool ok = getBuffer(self)->loadFromMemory(RSTRING_PTR(memory), RSTRING_LEN(memory));
    return ok ? Qtrue : Qfalse;
}

VALUE bufferGetSampleRate(VALUE self) {
    return UINT2NUM(getBuffer(self)->getSampleRate());
}

VALUE bufferGetDuration(VALUE self) {
    return DBL2NUM(getBuffer(self)->getDuration().asSeconds());
}

} // namespace

extern "C" void Init_SFMLAudio() {
    VALUE module = rb_define_module("SFMLAudio");

    VALUE music = rb_define_class_under(module, "Music", rb_cObject);
    rb_define_alloc_func(music, musicAlloc);
    rb_define_method(music, "open_from_memory", RUBY_METHOD_FUNC(musicOpenFromMemory), 1);
    rb_define_method(music, "play", RUBY_METHOD_FUNC(musicPlay), 0);
    rb_define_method(music, "pause", RUBY_METHOD_FUNC(musicPause), 0);
    rb_define_method(music, "stop", RUBY_METHOD_FUNC(musicStop), 0);
    rb_define_method(music, "stopped?", RUBY_METHOD_FUNC(musicStopped), 0);
    rb_define_method(music, "playing?", RUBY_METHOD_FUNC(musicPlaying), 0);
    rb_define_method(music, "paused?", RUBY_METHOD_FUNC(musicPaused), 0);
    rb_define_method(music, "set_loop", RUBY_METHOD_FUNC(musicSetLoop), 1);
    rb_define_method(music, "set_pitch", RUBY_METHOD_FUNC(musicSetPitch), 1);
    rb_define_method(music, "set_volume", RUBY_METHOD_FUNC(musicSetVolume), 1);
    rb_define_method(music, "get_volume", RUBY_METHOD_FUNC(musicGetVolume), 0);
    rb_define_method(music, "get_playing_offset", RUBY_METHOD_FUNC(musicGetPlayingOffset), 0);
    rb_define_method(music, "set_playing_offset", RUBY_METHOD_FUNC(musicSetPlayingOffset), 1);
    rb_define_method(music, "get_sample_rate", RUBY_METHOD_FUNC(musicGetSampleRate), 0);
    rb_define_method(music, "get_duration", RUBY_METHOD_FUNC(musicGetDuration), 0);
    rb_define_method(music, "set_loop_points", RUBY_METHOD_FUNC(musicSetLoopPoints), 2);

    VALUE sound = rb_define_class_under(module, "Sound", rb_cObject);
    rb_define_alloc_func(sound, soundAlloc);
    rb_define_method(sound, "set_buffer", RUBY_METHOD_FUNC(soundSetBuffer), 1);
    rb_define_method(sound, "play", RUBY_METHOD_FUNC(soundPlay), 0);
    rb_define_method(sound, "pause", RUBY_METHOD_FUNC(soundPause), 0);
    rb_define_method(sound, "stop", RUBY_METHOD_FUNC(soundStop), 0);
    rb_define_method(sound, "stopped?", RUBY_METHOD_FUNC(soundStopped), 0);
    rb_define_method(sound, "playing?", RUBY_METHOD_FUNC(soundPlaying), 0);
    rb_define_method(sound, "paused?", RUBY_METHOD_FUNC(soundPaused), 0);
    rb_define_method(sound, "set_pitch", RUBY_METHOD_FUNC(soundSetPitch), 1);
    rb_define_method(sound, "set_volume", RUBY_METHOD_FUNC(soundSetVolume), 1);
    rb_define_method(sound, "get_volume", RUBY_METHOD_FUNC(soundGetVolume), 0);
    rb_define_method(sound, "get_playing_offset", RUBY_METHOD_FUNC(soundGetPlayingOffset), 0);
    rb_define_method(sound, "set_playing_offset", RUBY_METHOD_FUNC(soundSetPlayingOffset), 1);
    rb_define_method(sound, "get_sample_rate", RUBY_METHOD_FUNC(soundGetSampleRate), 0);
    rb_define_method(sound, "get_duration", RUBY_METHOD_FUNC(soundGetDuration), 0);

    VALUE buffer = rb_define_class_under(module, "SoundBuffer", rb_cObject);
    rb_define_alloc_func(buffer, bufferAlloc);
    rb_define_method(buffer, "load_from_memory", RUBY_METHOD_FUNC(bufferLoadFromMemory), 1);
    rb_define_method(buffer, "get_sample_rate", RUBY_METHOD_FUNC(bufferGetSampleRate), 0);
    rb_define_method(buffer, "get_duration", RUBY_METHOD_FUNC(bufferGetDuration), 0);
}
