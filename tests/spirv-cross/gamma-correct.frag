#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Gamma correction with multiple color spaces
vec3 linearToSRGB(vec3 c) {
    return pow(c, vec3(1.0 / 2.2));
}

vec3 sRGBToLinear(vec3 c) {
    return pow(c, vec3(2.2));
}

float luminance(vec3 c) {
    return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

void main() {
    vec3 linear = vec3(uv.x, uv.y, uv.x * uv.y);
    vec3 srgb = linearToSRGB(linear);
    vec3 back = sRGBToLinear(srgb);
    
    float lum = luminance(back);
    
    fragColor = vec4(srgb * lum, 1.0);
}
