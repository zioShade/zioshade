#version 450
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;
void main() {
  int a = -1;
  uint b = uint(a);
  float c = float(b);
  fragColor = vec4(c, float(a), uv.y, 1.0);
}
