#version 450
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0) * 2.0 - 1.0;
    float a = atan(uv.y, uv.x);
    float r = length(uv);
    float rays = sin(a * 12.0) * 0.5 + 0.5;
    float glow = exp(-r * 3.0);
    vec3 col = vec3(1.0, 0.8, 0.3) * rays * glow;
    gl_FragColor = vec4(col, 1.0);
}
