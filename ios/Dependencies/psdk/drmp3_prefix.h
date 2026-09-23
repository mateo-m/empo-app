// Renames SFML's dr_mp3 copy. Forced into every SFML translation unit
// by the sfml cmake step in common.make.
//
// SDL_sound ships dr_mp3 v0.6.32 and SFML ships v0.7.3, and both export
// the same 22 names. mkxp links libSDL2_sound.a and the PSDK core links
// libsfml-audio-s.a, and both archive members load, so one app that
// holds both engines fails with 22 duplicate symbols.
//
// Only the exported functions get a new name. The two copies never
// share a type, because neither library includes the other's header.
#ifndef EMPO_DRMP3_PREFIX_H
#define EMPO_DRMP3_PREFIX_H

#define drmp3_bind_seek_table                    sfml_drmp3_bind_seek_table
#define drmp3_calculate_seek_points              sfml_drmp3_calculate_seek_points
#define drmp3_free                               sfml_drmp3_free
#define drmp3_get_mp3_and_pcm_frame_count        sfml_drmp3_get_mp3_and_pcm_frame_count
#define drmp3_get_mp3_frame_count                sfml_drmp3_get_mp3_frame_count
#define drmp3_get_pcm_frame_count                sfml_drmp3_get_pcm_frame_count
#define drmp3_init                               sfml_drmp3_init
#define drmp3_init_memory                        sfml_drmp3_init_memory
#define drmp3_init_memory_with_metadata          sfml_drmp3_init_memory_with_metadata
#define drmp3_malloc                             sfml_drmp3_malloc
#define drmp3_open_and_read_pcm_frames_f32       sfml_drmp3_open_and_read_pcm_frames_f32
#define drmp3_open_and_read_pcm_frames_s16       sfml_drmp3_open_and_read_pcm_frames_s16
#define drmp3_open_memory_and_read_pcm_frames_f32 sfml_drmp3_open_memory_and_read_pcm_frames_f32
#define drmp3_open_memory_and_read_pcm_frames_s16 sfml_drmp3_open_memory_and_read_pcm_frames_s16
#define drmp3_read_pcm_frames_f32                sfml_drmp3_read_pcm_frames_f32
#define drmp3_read_pcm_frames_s16                sfml_drmp3_read_pcm_frames_s16
#define drmp3_seek_to_pcm_frame                  sfml_drmp3_seek_to_pcm_frame
#define drmp3_uninit                             sfml_drmp3_uninit
#define drmp3_version                            sfml_drmp3_version
#define drmp3_version_string                     sfml_drmp3_version_string
#define drmp3dec_decode_frame                    sfml_drmp3dec_decode_frame
#define drmp3dec_f32_to_s16                      sfml_drmp3dec_f32_to_s16
#define drmp3dec_init                            sfml_drmp3dec_init

#endif
