# SPDX-License-Identifier: BSD-3-Clause
# Writes beep.wav: 100 ms of 880 Hz at -12 dB, 48 kHz 16-bit mono, with
# 5 ms fades. Run from this directory: python3 make-beep.py
import math, struct, wave

rate, n = 48000, 4800
fade = 240
with wave.open("beep.wav", "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(rate)
    frames = bytearray()
    for i in range(n):
        env = min(1.0, i / fade, (n - 1 - i) / fade)
        v = 0.25 * env * math.sin(2 * math.pi * 880 * i / rate)
        frames += struct.pack("<h", int(round(v * 32767)))
    w.writeframes(bytes(frames))
