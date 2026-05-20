#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Hemispherical dome / architectural
    float r = length(uv);
    // Dome shape (half circle)
    float dome = smoothstep(0.8, 0.78, r) * step(0.0, uv.y);
    // Ribs
    float a = atan(uv.y, uv.x);
    float ribs = smoothstep(0.02, 0.01, abs(sin(a * 8.0)));
    // Panels between ribs with shading
    float shade = 0.5 + 0.3 * cos(a * 4.0);
    vec3 stone = vec3(0.85, 0.8, 0.7);
    vec3 shadow = vec3(0.5, 0.45, 0.4);
    vec3 col = vec3(0.6, 0.7, 0.85); // sky
    vec3 dome_col = mix(shadow, stone, shade) * dome;
    dome_col = mix(dome_col, stone * 0.7, ribs * dome);
    col = mix(col, dome_col, dome);
    fragColor = vec4(col, 1.0);
}
