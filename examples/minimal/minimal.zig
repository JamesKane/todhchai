// SPDX-License-Identifier: BSD-3-Clause

// minimal, in Zig: the C program's calls through the generated bindings.

const td = @import("todhchai");

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern fn atol(s: [*:0]const u8) c_long;

pub fn main() u8 {
    var frames_left: c_long = if (getenv("TODHCHAI_MINIMAL_FRAMES")) |s| atol(s) else -1;

    const loop = td.loop_create() orelse return 1;
    defer td.loop_destroy(loop);
    const w = td.window_open(loop, "minimal (Zig)", 640, 360);
    const beep = td.sound_load("examples/minimal/beep.wav");
    var seq: u64 = 0;
    td.frame_request(loop, w);
    while (true) {
        const ev = td.loop_wait(loop, td.FOREVER, 0);
        for (ev.items[0..ev.count]) |*e| {
            switch (e.kind) {
                td.EV_CONFIGURE => seq = e.payload.configure.config_seq,
                td.EV_FRAME => {
                    var s: td.CpuSurface = undefined;
                    if (td.cpu_surface_acquire(loop, w, &s)) {
                        const t: u32 = @truncate(e.payload.frame.target / 16_000_000);
                        td.fill(&s, ((t *% 3) & 0xff) << 16 | ((t *% 5) & 0xff) << 8 | ((t *% 7) & 0xff));
                        _ = td.present(loop, w, &s, seq);
                        if (frames_left > 0) {
                            frames_left -= 1;
                            if (frames_left == 0) return 0;
                        }
                    }
                    td.frame_request(loop, w);
                },
                td.EV_KEY_DOWN => {
                    if (e.payload.key.usage == td.KEY_SPACE) _ = td.mixer_play(beep, 1.0);
                    if (e.payload.key.usage == td.KEY_ESCAPE) return 0;
                },
                td.EV_CLOSE, td.EV_QUIT => return 0,
                else => {},
            }
        }
    }
}
