// Tests: WGSL output with multiple function calls
// Tests that the WGSL output correctly handles multiple sequential function calls
#version 450
uniform int u_selector;

void set_red(inout vec3 color, float intensity) {
    color.r = intensity;
}

void set_green(inout vec3 color, float intensity) {
    color.g = intensity;
}

void set_blue(inout vec3 color, float intensity) {
    color.b = intensity;
}

void main() {
    vec3 col = vec3(0.0);
    float t = float(u_selector);
    if (u_selector > 0) {
        set_red(col, t);
        set_green(col, t * 0.5);
    } else {
        set_blue(col, 1.0);
    }
    gl_FragColor = vec4(col, 1.0);
}
