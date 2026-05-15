#version 450
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;
void main() {
  mat3 m = mat3(1.0);
  vec3 v = m[1];
  fragColor = vec4(v * uv.x, 1.0);
}
