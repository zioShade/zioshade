
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = subgroupShuffle(i32(0), 0);
}
