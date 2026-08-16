
@vertex
fn vtx() -> @builtin(position) vec4f {
  loop { continue; let cond = false; continuing { break if false; } }
  return vec4f(1);
}
    
