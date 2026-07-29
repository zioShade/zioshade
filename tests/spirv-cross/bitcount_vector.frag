#version 450
layout(location=0) out vec4 FragColor;

// Regression guard for OpBitCount on a vector whose result type is signed int
// (GLSL genIType bitCount(genUType)): uint2 operand -> int2 result. Metal's
// popcount returns the operand's type (uint2), so zioshade must wrap it in the
// result-type constructor (int2(popcount(uint2))) or Metal rejects the MSL
// ("cannot initialize int2 with uint2"). Caught by tools/msl_validity_sweep.sh.
void main()
{
    uvec2 u = uvec2(gl_FragCoord.xy);
    ivec2 c = bitCount(u);
    int s = c.x + c.y + bitCount(u.x);
    FragColor = vec4(float(s));
}
