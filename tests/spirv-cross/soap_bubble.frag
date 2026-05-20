#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Soap bubble thin-film interference
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    // Bubble shape
    float bubble = smoothstep(0.8, 0.78, r);
    // Thin film interference colors
    float thickness = 0.5 + 0.3 * sin(a * 3.0 + r * 5.0);
    float red = sin(thickness * 12.0) * 0.5 + 0.5;
    float green = sin(thickness * 12.0 + 2.09) * 0.5 + 0.5;
    float blue = sin(thickness * 12.0 + 4.18) * 0.5 + 0.5;
    vec3 col = vec3(red, green, blue) * bubble;
    // Specular highlight
    float spec = exp(-length(uv - vec2(-0.2, 0.3)) * 10.0);
    col += vec3(spec) * bubble;
    col += vec3(0.05) * (1.0 - bubble);
    fragColor = vec4(col, 1.0);
}
