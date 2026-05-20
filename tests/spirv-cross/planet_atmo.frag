#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Planet with atmosphere
    float r = length(uv);
    float planet = smoothstep(0.5, 0.49, r);
    // Surface
    float lat = asin(clamp(uv.y / max(r, 0.001), -1.0, 1.0));
    float lon = atan(uv.x, uv.y);
    float land = smoothstep(0.1, 0.15, sin(lat * 8.0) * cos(lon * 6.0));
    vec3 ocean = vec3(0.1, 0.2, 0.5);
    vec3 land_col = vec3(0.2, 0.5, 0.15);
    vec3 surface = mix(ocean, land_col, land);
    // Atmosphere glow
    float atmo = smoothstep(0.45, 0.55, r) * (1.0 - smoothstep(0.55, 0.75, r));
    vec3 col = surface * planet;
    col += vec3(0.3, 0.5, 0.9) * atmo;
    // Stars background
    float star = fract(sin(dot(floor(uv * 200.0), vec2(127.1, 311.7))) * 43758.5453);
    col += vec3(star * step(0.97, star) * (1.0 - planet) * 0.5);
    fragColor = vec4(col, 1.0);
}
