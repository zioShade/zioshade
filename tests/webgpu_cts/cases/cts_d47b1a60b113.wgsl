
@vertex fn vtx() -> @builtin(position) vec4f {
  { const x = 1; { const_assert x == 1; }}
  return vec4f(1);
}
