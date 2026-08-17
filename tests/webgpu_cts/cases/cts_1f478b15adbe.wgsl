
enable subgroups;
@compute @workgroup_size(16)
fn main() {
  _ = subgroupShuffle(0, 0);
}
