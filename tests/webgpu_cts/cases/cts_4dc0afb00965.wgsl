 const a = 4;
    const b = 5;
    @workgroup_size(a, b, a + b)
      @compute fn main() {}
