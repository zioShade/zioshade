// Test: Chroma key (green screen) effect
#version 450

layout(binding = 0) uniform sampler2D uVideo;
layout(binding = 1) uniform sampler2D uBackground;

layout(location = 0) out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    
    vec4 video = texture(uVideo, uv);
    vec4 bg = texture(uBackground, uv);
    
    float green = video.g;
    float rb = max(video.r, video.b);
    float chroma = green - rb;
    
    float threshold = 0.3;
    float edge = 0.1;
    float alpha = smoothstep(threshold - edge, threshold + edge, chroma);
    alpha = 1.0 - clamp(alpha, 0.0, 1.0);
    
    vec3 result = mix(bg.rgb, video.rgb, alpha);
    fragColor = vec4(result, 1.0);
}
