
#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    float d = length(uv - vec2(0.5));
    float ring = fract(d * 10.0);
    FragColor = vec4(ring, ring * 0.5, 1.0 - ring, 1.0);
}
