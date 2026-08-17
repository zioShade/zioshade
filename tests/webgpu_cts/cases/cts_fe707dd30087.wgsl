
      

      @compute @workgroup_size(1)
      fn main() {
        const c = determinant(mat3x3(0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0));
      }
