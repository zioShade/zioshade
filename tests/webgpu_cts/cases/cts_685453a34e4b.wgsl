
enable subgroups;
enable f16;
@compute @workgroup_size(1)
fn main() {
  _ = subgroupMax(0.0h);
}
