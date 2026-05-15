#version 450
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;
void main() {
  vec2 a = uv;
  vec3 b = vec3(a, 0.5);
  vec4 c = vec4(b.zyx, 1.0);
  fragColor = c;
}
