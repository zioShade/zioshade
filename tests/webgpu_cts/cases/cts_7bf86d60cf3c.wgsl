
enable subgroups;
enable f16;
@compute @workgroup_size(1)
fn main() {
  let res : vec2<f16> = subgroupBroadcast(vec2(0.0h, 0.0h), 0);
}
