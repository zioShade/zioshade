
@vertex
fn vtx() -> @builtin(position) vec4f {
  for (;true;) { continue; }
  return vec4f(1);
}
    
