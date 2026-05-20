#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Topographic mountain landscape
    float mountain1 = smoothstep(0.0, 0.1, uv.y - (0.3 - abs(uv.x) * 0.4));
    float mountain2 = smoothstep(0.0, 0.1, uv.y - (0.15 - abs(uv.x - 0.3) * 0.3));
    float mountain3 = smoothstep(0.0, 0.1, uv.y - (0.4 - abs(uv.x + 0.2) * 0.25));
    // Sky gradient
    vec3 sky = mix(vec3(0.3, 0.4, 0.8), vec3(0.8, 0.6, 0.3), 1.0 - uv.y);
    // Mountains
    vec3 mtn1 = vec3(0.2, 0.3, 0.25) * (1.0 - mountain1);
    vec3 mtn2 = vec3(0.15, 0.25, 0.2) * (1.0 - mountain2);
    vec3 mtn3 = vec3(0.25, 0.35, 0.3) * (1.0 - mountain3);
    // Sun
    float sun = smoothstep(0.12, 0.1, length(uv - vec2(0.3, 0.6)));
    vec3 col = sky * mountain1 * mountain2 * mountain3;
    col += mtn3 * (1.0 - mountain3);
    col += mtn1 * mountain3 * (1.0 - mountain1);
    col += mtn2 * mountain1 * (1.0 - mountain2);
    col += vec3(1.0, 0.9, 0.5) * sun;
    fragColor = vec4(col, 1.0);
}
