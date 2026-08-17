
enable f16;
@fragment
fn main() {
  var src : vec4<f16>;
  let dst = bitcast<vec2<u32>>(src);
}
