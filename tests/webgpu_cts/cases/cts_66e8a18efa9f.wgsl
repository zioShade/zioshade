
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  let res : u32 = subgroupOr(0u);
}
