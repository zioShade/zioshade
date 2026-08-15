
@vertex
fn vtx() -> @builtin(position) vec4f {
  for (;;) { if true { break; } }
  return vec4f(1);
}
    
