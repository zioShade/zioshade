#version 450
// Test: saturation adjustment
vec3 adjustSat(vec3 col, float sat) {
    float lum = dot(col, vec3(0.299, 0.587, 0.114));
    return mix(vec3(lum), col, sat);
}
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 base = vec3(uv, 0.5);
    vec3 desat = adjustSat(base, uv.x);
    gl_FragColor = vec4(desat, 1.0);
}
