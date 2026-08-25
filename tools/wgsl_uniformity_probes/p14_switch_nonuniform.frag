// Staging driver for uniformity probe p14_switch_nonuniform. Exists ONLY so
// tools/wgsl_browser_check.mjs stages this probe: the harness compiles
// this trivial GLSL through glslang and zioshade, then ZWB_OVERRIDE_DIR
// replaces the output with p14_switch_nonuniform.wgsl (the probe text) before the
// browser leg. Same text for every probe, as in the original probing
// session.
#version 450
layout(binding=0) uniform sampler2D tex;
layout(binding=1) uniform Globals { float flag; vec3 res; };
layout(location=0) out vec4 fragColor;
void main(){ fragColor = texture(tex, vec2(0.5)); }
