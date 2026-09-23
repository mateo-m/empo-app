// Renames LiteCGSS's libnsgif copy. Forced into every LiteCGSS
// translation unit by the litecgss cmake step in common.make.
//
// mkxp-z vendors its own libnsgif and exports the same 8 names. Its
// gif_animation holds 4 extra trailing members, so it is 176 bytes
// against LiteCGSS's 152. The app links libmkxpz-core.a with
// -Wl,-force_load (ios/Empo/project.yml), so the plain names always
// resolve to mkxp's copy, LiteCGSS's own archive members never load,
// and gif_create memsets 176 bytes into a 152-byte allocation. The
// process then dies in the next malloc call.
//
// The types get a new name too. A file that misses this header then
// fails to compile instead of binding to mkxp's copy.
#ifndef EMPO_NSGIF_PREFIX_H
#define EMPO_NSGIF_PREFIX_H

#define gif_create             cgss_gif_create
#define gif_initialise         cgss_gif_initialise
#define gif_decode_frame       cgss_gif_decode_frame
#define gif_finalise           cgss_gif_finalise

#define lzw_context_create     cgss_lzw_context_create
#define lzw_context_destroy    cgss_lzw_context_destroy
#define lzw_decode             cgss_lzw_decode
#define lzw_decode_init        cgss_lzw_decode_init

#define gif_animation          cgss_gif_animation
#define gif_frame              cgss_gif_frame
#define gif_bitmap_callback_vt cgss_gif_bitmap_callback_vt
#define gif_result             cgss_gif_result

#endif
