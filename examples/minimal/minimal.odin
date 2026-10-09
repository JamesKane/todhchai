// SPDX-License-Identifier: BSD-3-Clause

// minimal, in Odin: the C program's calls through the generated bindings.

package minimal

import "core:c/libc"
import td "../../lib/capi/odin/todhchai"

main :: proc() {
	limit := libc.getenv("TODHCHAI_MINIMAL_FRAMES")
	frames_left := limit != nil ? int(libc.atol(limit)) : -1

	loop := td.loop_create()
	if loop == nil do libc.exit(1)
	defer td.loop_destroy(loop)
	w := td.window_open(loop, "minimal (Odin)", 640, 360)
	beep := td.sound_load("examples/minimal/beep.wav")
	seq: u64 = 0
	td.frame_request(loop, w)
	for {
		ev := td.loop_wait(loop, td.FOREVER, 0)
		for &e in ev.items[:ev.count] {
			switch e.kind {
			case td.EV_CONFIGURE:
				seq = e.configure.config_seq
			case td.EV_FRAME:
				s: td.CPU_Surface
				if td.cpu_surface_acquire(loop, w, &s) {
					t := u32(e.frame.target / 16_000_000)
					td.fill(&s, ((t * 3) & 0xff) << 16 | ((t * 5) & 0xff) << 8 | ((t * 7) & 0xff))
					td.present(loop, w, &s, seq)
					if frames_left > 0 {
						frames_left -= 1
						if frames_left == 0 do return
					}
				}
				td.frame_request(loop, w)
			case td.EV_KEY_DOWN:
				if e.key.usage == td.KEY_SPACE do td.mixer_play(beep, 1.0)
				if e.key.usage == td.KEY_ESCAPE do return
			case td.EV_CLOSE, td.EV_QUIT:
				return
			}
		}
	}
}
