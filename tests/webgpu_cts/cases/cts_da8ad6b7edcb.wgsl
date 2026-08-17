
@vertex
fn vtx() -> @builtin(position) vec4f {
  loop { if false { break; } continuing { loop { if false { break; } continue; } } }
  return vec4f(1);
}
    
