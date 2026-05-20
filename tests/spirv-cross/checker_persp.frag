#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Checkerboard with perspective warp
    float perspective = 1.0 + uv.y * 0.5;
    float x = uv.x * perspective * 10.0;
    float y = uv.y * 10.0;
    float checker = step(0.0, sin(x) * sin(y));
    // Fade with distance
    float fade = smoothstep(1.5, 0.3, length(uv));
    vec3 black = vec3(0.05);
    vec3 white = vec3(0.95);
    vec3 col = mix(black, white, checker) * fade;
    fragColor = vec4(col, 1.0);
}
