// Tests: struct returned from function, then used in array init
precision mediump float;
uniform vec2 u_resolution;

struct Color {
    float r;
    float g;
    float b;
};

Color heatMap(float t) {
    Color c;
    c.r = clamp(t * 3.0, 0.0, 1.0);
    c.g = clamp(t * 3.0 - 1.0, 0.0, 1.0);
    c.b = clamp(t * 3.0 - 2.0, 0.0, 1.0);
    return c;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    float values[4];
    values[0] = length(uv);
    values[1] = length(uv - vec2(1.0, 0.0));
    values[2] = length(uv - vec2(0.0, 1.0));
    values[3] = length(uv - vec2(1.0));
    
    float minDist = 999.0;
    for (int i = 0; i < 4; i++) {
        if (values[i] < minDist) minDist = values[i];
    }
    
    Color c = heatMap(minDist * 2.0);
    gl_FragColor = vec4(c.r, c.g, c.b, 1.0);
}
