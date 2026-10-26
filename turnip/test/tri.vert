#version 450
// per-draw vertex data at a dynamic offset (what Metal's setVertexBytes: carries): 3 x { vec4 pos, vec4 color }
layout(set = 0, binding = 0, std430) readonly buffer V { vec4 v[6]; } vb;
layout(location = 0) out vec4 color;
layout(location = 1) out vec2 uv;
void main()
{
   gl_Position = vb.v[gl_VertexIndex * 2];
   color = vb.v[gl_VertexIndex * 2 + 1];
   uv = gl_Position.xy * 0.5 + 0.5;
}
