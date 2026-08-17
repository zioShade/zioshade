
enable subgroups;
@compute @workgroup_size(16)
fn main() {
  let x = subgroupMin(0);
}
