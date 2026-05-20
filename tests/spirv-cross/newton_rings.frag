#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Light interference (Newton's rings)
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    // Thin film interference pattern
    float gap = r * r * 5.0;
    float red = cos(gap * 20.0) * 0.5 + 0.5;
    float green = cos(gap * 25.0 + 1.0) * 0.5 + 0.5;
    float blue = cos(gap * 30.0 + 2.0) * 0.5 + 0.5;
    vec3 col = vec3(red, green, blue) * smoothstep(1.0, 0.8, r);
    // Center bright spot
    col += vec3(0.2) * exp(-r * r * 20.0);
    fragColor = vec4(col, 1.0);
}
