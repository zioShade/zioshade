// Tests: multiple return paths with different expression complexity
precision mediump float;
uniform vec2 u_resolution;

vec3 getColor(float t) {
    if (t < 0.25) {
        return vec3(0.0, t * 4.0, 1.0);
    } else if (t < 0.5) {
        return vec3((t - 0.25) * 4.0, 1.0, 1.0 - (t - 0.25) * 4.0);
    } else if (t < 0.75) {
        return vec3(1.0, 1.0 - (t - 0.5) * 4.0, 0.0);
    } else {
        return vec3(1.0 - (t - 0.75) * 4.0, 0.0, (t - 0.75) * 4.0);
    }
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    vec3 col = getColor(uv.x);
    gl_FragColor = vec4(col, 1.0);
}
