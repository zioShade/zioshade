#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Amiga boing ball (classic 3D sphere with checkerboard)
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    // Sphere shading
    float shade = sqrt(max(1.0 - r * r, 0.0));
    // Checkerboard mapped to sphere
    float u = a / 3.14159;
    float v = asin(clamp(uv.y / max(r, 0.001), -1.0, 1.0)) / 1.5708;
    float checker = step(0.0, sin(u * 8.0) * sin(v * 8.0));
    vec3 white = vec3(1.0) * shade;
    vec3 red = vec3(0.9, 0.1, 0.1) * shade;
    vec3 col = mix(white, red, checker) * step(r, 1.0);
    // Specular
    float spec = exp(-length(uv - vec2(-0.3, 0.3)) * 8.0) * 0.5;
    col += vec3(spec) * step(r, 1.0);
    // Shadow
    float shadow = smoothstep(0.3, 0.25, length(uv - vec2(0.15, -1.1)));
    col += vec3(0.0) * shadow * (1.0 - step(r, 1.0)) * 0.3;
    fragColor = vec4(col, 1.0);
}
