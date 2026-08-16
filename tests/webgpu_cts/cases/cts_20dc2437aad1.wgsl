
@vertex
fn vtx() -> @builtin(position) vec4f {
  loop { let cond = false; continue; continuing { break if cond; } }
  return vec4f(1);
}
    
