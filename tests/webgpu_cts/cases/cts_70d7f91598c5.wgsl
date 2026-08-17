
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = subgroupShuffle(0, 0);
}
