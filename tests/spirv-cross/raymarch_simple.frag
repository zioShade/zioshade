#version 310 es
precision highp float;
out vec4 fragColor;

vec3 rotateY(vec3 p, float angle) {
    float c = cos(angle);
    float s = sin(angle);
    return vec3(c * p.x + s * p.z, p.y, -s * p.x + c * p.z);
}

float scene(vec3 p) {
    p = rotateY(p, gl_FragCoord.x * 0.01);
    return length(p) - 1.0;
}

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    vec3 ro = vec3(0.0, 0.0, 3.0);
    vec3 rd = normalize(vec3(uv, -1.0));
    
    float t = 0.0;
    for (int i = 0; i < 32; i++) {
        float d = scene(ro + rd * t);
        if (d < 0.001) break;
        t += d;
    }
    
    vec3 col = vec3(0.1);
    if (t < 10.0) {
        vec3 p = ro + rd * t;
        col = vec3(0.5) + 0.5 * cos(p * 3.0 + vec3(0.0, 1.0, 2.0));
    }
    fragColor = vec4(col, 1.0);
}
