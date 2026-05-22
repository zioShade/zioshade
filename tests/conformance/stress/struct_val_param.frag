// Tests: by-value struct parameter with member access inside function
precision mediump float;
uniform vec2 u_resolution;

struct Light {
    vec3 pos;
    vec3 color;
    float intensity;
};

float computeLight(Light l, vec2 uv) {
    float d = length(uv - l.pos.xy);
    return l.intensity / (d * d + 0.01) * l.color.r;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    Light l;
    l.pos = vec3(0.5, 0.5, 1.0);
    l.color = vec3(1.0, 0.8, 0.6);
    l.intensity = 2.0;
    
    float v = computeLight(l, uv);
    gl_FragColor = vec4(vec3(fract(v)), 1.0);
}
