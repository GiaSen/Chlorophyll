#version 450
// a texture tap with a per-draw constant offset (CoreAnimation's common shape)
layout(location = 0) in vec4 color;
layout(location = 1) in vec2 uv;
layout(location = 0) out vec4 o;
layout(set = 0, binding = 1) uniform sampler2D t;
layout(set = 0, binding = 2) uniform U { vec4 off; } u;
void main() { o = textureLod(t, uv + u.off.xy, 0.0) * color; }
