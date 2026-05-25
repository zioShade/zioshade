// Tests: vec3 to vec4 promotion patterns
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    vec3 a = vec3(1.0, 2.0, 3.0);
    vec4 b = vec4(a, 4.0);
    vec3 c = b.rgb;
    vec2 d = b.xy + c.yz;
    vec4 e = vec4(d, b.z, b.w);
    fragColor = e;
}
