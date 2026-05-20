#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Fresnel lens rings v2
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    float zone_r = floor(r * 12.0) / 12.0;
    float zone_d = r - zone_r;
    float edge = smoothstep(0.01, 0.005, zone_d);
    float hue = zone_r * 5.0 + a * 0.5;
    vec3 col = vec3(
        sin(hue * 6.28) * 0.5 + 0.5,
        sin(hue * 6.28 + 2.09) * 0.5 + 0.5,
        sin(hue * 6.28 + 4.18) * 0.5 + 0.5
    );
    col = mix(col * 0.3, col, edge);
    col *= smoothstep(1.0, 0.9, r);
    fragColor = vec4(col, 1.0);
}
