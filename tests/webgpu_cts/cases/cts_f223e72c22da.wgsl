
@vertex
fn vtx() -> @builtin(position) vec4f {
  while true { if true { continue; } }
  return vec4f(1);
}
    
