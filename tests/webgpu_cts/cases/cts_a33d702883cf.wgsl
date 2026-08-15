
@vertex
fn vtx() -> @builtin(position) vec4f {
  loop { continuing { break if true; } }
  return vec4f(1);
}
    
