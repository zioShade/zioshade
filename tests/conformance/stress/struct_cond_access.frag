// Tests: struct member access across conditional + swizzle
precision mediump float;
uniform vec2 u_resolution;

struct Color {
    vec3 rgb;
    float alpha;
};

Color makeColor(float r, float g, float b) {
    Color c;
    c.rgb = vec3(r, g, b);
    c.alpha = 1.0;
    return c;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    Color c1 = makeColor(uv.x, uv.y, 0.5);
    Color c2 = makeColor(0.3, 0.7, uv.x * uv.y);
    
    vec3 result;
    if (uv.x > 0.5) {
        result = c1.rgb;
    } else {
        result = c2.rgb;
    }
    
    gl_FragColor = vec4(result, 1.0);
}
