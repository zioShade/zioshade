#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Sun with corona
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    // Sun disk
    float disk = smoothstep(0.3, 0.28, r);
    // Corona rays
    float rays = pow(max(cos(a * 12.0), 0.0), 4.0);
    float corona = rays * exp(-r * 3.0) * 0.5;
    // Inner detail
    float spots = smoothstep(0.08, 0.06, length(uv - vec2(0.1, 0.05)));
    vec3 sun_col = vec3(1.0, 0.8, 0.2);
    vec3 corona_col = vec3(1.0, 0.5, 0.1);
    vec3 col = vec3(0.0, 0.0, 0.05);
    col += corona_col * corona;
    col = mix(col, sun_col, disk);
    col = mix(col, vec3(0.8, 0.6, 0.1), spots * disk);
    // Flare
    col += vec3(0.3, 0.2, 0.1) * exp(-r * 2.0);
    fragColor = vec4(col, 1.0);
}
