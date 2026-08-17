
enable f16;
@fragment
fn main() {
  var src : vec4<f16>;
  let dst = bitcast<vec2i>(src);
}
