#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float r = length(uv);
    
    mat2 m;
    if (r < 0.5) {
        float a = uv.x * 2.0;
        m = mat2(cos(a), -sin(a), sin(a), cos(a));
    } else {
        float s = 0.5 + r;
        m = mat2(s, 0.0, 0.0, s);
    }
    
    vec2 transformed = m * uv;
    float val = length(transformed);
    vec3 col = vec3(val);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
