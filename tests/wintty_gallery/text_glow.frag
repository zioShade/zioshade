#version 430 core

layout(binding = 1, std140) uniform Globals {
    uniform vec3  iResolution;
    uniform float iTime;
    uniform float iTimeDelta;
    uniform float iFrameRate;
    uniform int   iFrame;
    uniform float iChannelTime[4];
    uniform vec3  iChannelResolution[4];
    uniform vec4  iMouse;
    uniform vec4  iDate;
    uniform float iSampleRate;
    uniform vec4  iCurrentCursor;
    uniform vec4  iPreviousCursor;
    uniform vec4  iCurrentCursorColor;
    uniform vec4  iPreviousCursorColor;
    uniform int   iCurrentCursorStyle;
    uniform int   iPreviousCursorStyle;
    uniform int   iCursorVisible;
    uniform float iTimeCursorChange;
    uniform float iTimeFocus;
    uniform int iFocus;
    uniform vec3  iPalette[256];
    uniform vec3  iBackgroundColor;
    uniform vec3  iForegroundColor;
    uniform vec3  iCursorColor;
    uniform vec3  iCursorText;
    uniform vec3  iSelectionForegroundColor;
    uniform vec3  iSelectionBackgroundColor;
};

#define CURSORSTYLE_BLOCK        0
#define CURSORSTYLE_BLOCK_HOLLOW 1
#define CURSORSTYLE_BAR          2
#define CURSORSTYLE_UNDERLINE    3
#define CURSORSTYLE_LOCK         4

layout(binding = 0) uniform sampler2D iChannel0;

// These are unused currently by Ghostty:
// layout(binding = 1) uniform sampler2D iChannel1;
// layout(binding = 2) uniform sampler2D iChannel2;
// layout(binding = 3) uniform sampler2D iChannel3;

layout(location = 0) in vec4 gl_FragCoord;
layout(location = 0) out vec4 _fragColor;

#define texture2D texture

void mainImage( out vec4 fragColor, in vec2 fragCoord );
void main() { mainImage (_fragColor, gl_FragCoord.xy); }

// Written for the wintty shader gallery. License: MIT (wintty project).
//
// Text glow: a soft bloom around bright pixels. Static effect; the glow
// follows whatever the terminal is showing, so it reads as luminescent
// text without touching anything else.

const float GLOW_THRESHOLD = 0.55; // luminance above which a pixel glows
const float GLOW_INTENSITY = 0.35; // how much glow is added back
const float GLOW_RADIUS    = 3.0;  // in pixels, at the base scale

float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }

vec3 brightPass(vec2 uv) {
    vec3 c = texture(iChannel0, uv).rgb;
    float l = luma(c);
    return c * smoothstep(GLOW_THRESHOLD, GLOW_THRESHOLD + 0.2, l);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord.xy / iResolution.xy;
    vec4 base = texture(iChannel0, uv);

    vec2 px = GLOW_RADIUS / iResolution.xy;

    // 12-tap ring blur of the bright pass, two radii for a softer falloff.
    vec3 glow = vec3(0.0);
    const int TAPS = 12;
    const float TAU = 6.28318530718;
    for (int r = 1; r <= 2; r++) {
        float scale = float(r) * 0.5;
        float w = 1.0 / float(r) / float(TAPS);
        for (int i = 0; i < TAPS; i++) {
            float a = (float(i) + 0.5) / float(TAPS) * TAU;
            vec2 off = vec2(cos(a), sin(a)) * px * scale;
            glow += brightPass(uv + off) * w;
        }
    }

    fragColor = vec4(base.rgb + glow * GLOW_INTENSITY, base.a);
}

