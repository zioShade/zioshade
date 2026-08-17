
@vertex
fn vtx() -> @builtin(position) vec4f {
  loop { if true { break; } }
  return vec4f(1);
}
    
