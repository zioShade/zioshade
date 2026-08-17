
enable subgroups;
enable f16;
@compute @workgroup_size(1)
fn main() {
  let res : f16 = subgroupMax(0.0h);
}
