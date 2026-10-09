// SPDX-License-Identifier: BSD-3-Clause

// minimal, in C (sdk.md §3): a window whose color cycles, a beep on space,
// escape or closing quits. TODHCHAI_MINIMAL_FRAMES=N stops after N frames
// (for tests). Build: see examples/minimal/README.md.

#include <stdlib.h>
#include <todhchai/todhchai.h>

int main(void) {
  const char *limit = getenv("TODHCHAI_MINIMAL_FRAMES");
  long frames_left = limit ? atol(limit) : -1;

  td_loop *loop = td_loop_create();
  if (!loop) return 1;
  td_window w = td_window_open(loop, "minimal (C)", 640, 360);
  td_sound beep = td_sound_load("examples/minimal/beep.wav");
  uint64_t seq = 0;
  td_frame_request(loop, w);
  for (;;) {
    td_events ev = td_loop_wait(loop, TD_FOREVER, 0);
    for (size_t i = 0; i < ev.count; i++) {
      const td_event *e = &ev.items[i];
      switch (e->kind) {
      case TD_EV_CONFIGURE: seq = e->configure.config_seq; break;
      case TD_EV_FRAME: {
        td_cpu_surface s;
        if (td_cpu_surface_acquire(loop, w, &s)) {
          uint32_t t = (uint32_t)(e->frame.target / 16000000u);  // a step per ~16 ms
          td_fill(&s, ((t * 3) & 0xff) << 16 | ((t * 5) & 0xff) << 8 | ((t * 7) & 0xff));
          td_present(loop, w, &s, seq);
          if (frames_left > 0 && --frames_left == 0) goto done;
        }
        td_frame_request(loop, w);
      } break;
      case TD_EV_KEY_DOWN:
        if (e->key.usage == TD_KEY_SPACE) td_mixer_play(beep, 1.0f);
        if (e->key.usage == TD_KEY_ESCAPE) goto done;
        break;
      case TD_EV_CLOSE: case TD_EV_QUIT: goto done;
      }
    }
  }
done:
  td_loop_destroy(loop);
  return 0;
}
