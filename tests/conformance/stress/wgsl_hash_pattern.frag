#version 450
uniform vec2 u_resolution;
out vec4 fragColor;

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    float h = hash(uv);
    vec3 col = vec3(h);
    fragColor = vec4(col, 1.0);
}
