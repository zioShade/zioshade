
@vertex
fn vtx() -> @builtin(position) vec4f {
  let a = !(1 == 2);
  return vec4f(1);
}
    
