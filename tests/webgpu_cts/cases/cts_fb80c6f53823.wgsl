
@vertex
fn vtx() -> @builtin(position) vec4f {
  switch(1) { default: { if true { break; } } }
  return vec4f(1);
}
    
