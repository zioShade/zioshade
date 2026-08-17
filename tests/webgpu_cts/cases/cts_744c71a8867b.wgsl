
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  let res : u32 = subgroupShuffle(0u, 0);
}
