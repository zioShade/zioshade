#version 450
uniform vec2 u_resolution;
out vec4 fragColor;

// Nested if/else with early return
float branchSelect(vec2 uv) {
    if (uv.x > 0.75) {
        return sin(uv.x * 10.0);
    } else if (uv.x > 0.5) {
        return cos(uv.x * 8.0);
    } else if (uv.x > 0.25) {
        return abs(uv.x - 0.375) * 4.0;
    } else {
        return uv.x * 4.0;
    }
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    float val = branchSelect(uv);
    fragColor = vec4(val, val, val, 1.0);
}
