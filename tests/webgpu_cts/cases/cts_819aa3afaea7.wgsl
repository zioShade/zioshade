
@vertex
fn vtx() -> @builtin(position) vec4f {
  let a = (1 == 2) & (3 == 4);
  return vec4f(1);
}
    
