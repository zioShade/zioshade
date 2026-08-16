


fn subvert() {
  
}

@vertex
fn vtx() -> @builtin(position) vec4f {
  
  subvert();
  return vec4f(1);
}

fn subfrag() {
  discard;
}

@fragment
fn frag() -> @location(0) vec4f {
  
  subfrag();
  return vec4f(1);
}

fn subcomp() {
  
}

@compute
@workgroup_size(1)
fn comp() {
  
  subcomp();
}
