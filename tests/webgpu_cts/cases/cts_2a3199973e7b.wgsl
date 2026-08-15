
@vertex
fn vtx() -> @builtin(position) vec4f {
  while true { switch(1) { default: { continue; } } }
  return vec4f(1);
}
    
