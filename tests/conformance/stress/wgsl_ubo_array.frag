// Test: uniform struct array
#version 450

struct LightData {
    vec4 position;
    vec4 color;
};

layout(binding = 0) uniform Lights {
    LightData lights[4];
    int count;
};

layout(location = 0) out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    vec3 accum = vec3(0.0);
    
    for (int i = 0; i < count && i < 4; i++) {
        vec3 lightPos = lights[i].position.xyz;
        vec3 lightCol = lights[i].color.rgb;
        float dist = length(lightPos.xy - uv);
        accum += lightCol / (1.0 + dist * 5.0);
    }
    
    fragColor = vec4(accum, 1.0);
}
