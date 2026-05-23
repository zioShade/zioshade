#version 450
uniform vec2 u_resolution;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    // Multiple uniforms
    float aspect = u_resolution.x / u_resolution.y;
    vec2 adjusted = vec2(uv.x * aspect, uv.y);
    float d = length(adjusted - vec2(aspect * 0.5, 0.5));
    fragColor = vec4(vec3(1.0 - smoothstep(0.0, 0.5, d)), 1.0);
}
