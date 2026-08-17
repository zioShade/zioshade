
enable subgroups;
enable f16;
@compute @workgroup_size(1)
fn main() {
  _ = subgroupMin(0.0h);
}
