#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Fresnel lens rings
    float r = length(uv);
    float ring = sin(r * 40.0) * 0.5 + 0.5;
    // Center bright spot
    float center = exp(-r * r * 10.0);
    // Prismatic color
    float a = atan(uv.y, uv.x);
    vec3 col = vec3(
        sin(ring * 3.14 + a) * 0.5 + 0.5,
        sin(ring * 3.14 + a + 2.09) * 0.5 + 0.5,
        sin(ring * 3.14 + a + 4.18) * 0.5 + 0.5
    );
    col *= ring * 0.5 + 0.3;
    col += vec3(center);
    col *= smoothstep(1.0, 0.8, r);
    fragColor = vec4(col, 1.0);
}
