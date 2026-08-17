
enable subgroups;
enable f16;
@compute @workgroup_size(1)
fn main() {
  let res : vec4<f16> = subgroupBroadcast(vec4(0.0h, 0.0h, 0.0h, 0.0h), 0);
}
