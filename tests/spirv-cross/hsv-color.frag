#version 450

layout(location = 0) in float u;
layout(location = 0) out vec4 fragColor;

vec3 hsv2rgb(vec3 c) {
    float h = c.x * 6.0;
    float s = c.y;
    float v = c.z;
    float i = floor(h);
    float f = h - i;
    float p = v * (1.0 - s);
    float q = v * (1.0 - s * f);
    float t = v * (1.0 - s * (1.0 - f));
    int ii = int(i) % 6;
    if (ii == 0) return vec3(v, t, p);
    if (ii == 1) return vec3(q, v, p);
    if (ii == 2) return vec3(p, v, t);
    if (ii == 3) return vec3(p, q, v);
    if (ii == 4) return vec3(t, p, v);
    return vec3(v, p, q);
}

void main()
{
    vec3 hsv = vec3(u, 0.8, 0.9);
    vec3 rgb = hsv2rgb(hsv);
    fragColor = vec4(rgb, 1.0);
}
