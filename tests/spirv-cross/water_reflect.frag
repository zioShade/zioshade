#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Simplified water reflection using mix
    float is_sky = step(0.0, uv.y);
    // Sky
    vec3 sky = mix(vec3(0.2, 0.3, 0.7), vec3(0.6, 0.7, 0.9), uv.y * 0.5 + 0.5);
    // Water (below horizon)
    float reflect_y = -uv.y;
    vec3 water = mix(vec3(0.1, 0.2, 0.5), vec3(0.3, 0.5, 0.7), reflect_y);
    float ripple = sin(uv.x * 20.0) * 0.02;
    water = water * (0.7 + ripple);
    vec3 col = mix(water, sky, is_sky);
    fragColor = vec4(col, 1.0);
}
