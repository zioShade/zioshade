// Tests: conditional discard in fragment shader
#version 450
uniform float u_threshold;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    float d = distance(uv, vec2(0.5));
    if (d > u_threshold) discard;
    float intensity = 1.0 - d * 2.0;
    gl_FragColor = vec4(vec3(intensity), 1.0);
}
