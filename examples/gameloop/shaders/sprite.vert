// SPDX-License-Identifier: BSD-3-Clause
// Instanced sprites through the root pointer: instance i is sprites.s[i],
// and each draws as two triangles.
#version 460
#extension GL_EXT_buffer_reference : require

struct Sprite {
  vec2 position;  // the center, in clip space
  vec2 size;      // half extents, in clip space
  vec4 color;
};
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer Sprites { Sprite s[]; };
layout(push_constant) uniform Root { Sprites sprites; } root;

layout(location = 0) out vec4 color;

void main() {
  vec2 corners[6] = vec2[](vec2(-1, -1), vec2(1, -1), vec2(-1, 1), vec2(1, -1), vec2(1, 1), vec2(-1, 1));
  Sprite s = root.sprites.s[gl_InstanceIndex];
  gl_Position = vec4(s.position + corners[gl_VertexIndex] * s.size, 0.0, 1.0);
  color = s.color;
}
