#include <cuda.h>
#include <stdio.h>

__global__ void dkernel() {
   printf("Hello world.\n"); 
}
int main(){
 dkernel<<<2,32>>> ();
 cudaDeviceSynchronize(); 
 cudaError_t e = cudaGetLastError();        // launch/config errors
if (e == cudaSuccess) e = cudaDeviceSynchronize(); // runtime errors
if (e != cudaSuccess) printf("CUDA error: %s\n", cudaGetErrorString(e));
 return 0; 
}

// kernel<<<gridDim, blockDim>>>(args);
// First number (1): how many thread blocks are in the grid.
// Second number (32): how many threads are in each block.
// Both arguments can be 3D (dim3), e.g. <<<dim3(4,4), dim3(16,16)>>>. 
// Inside the kernel, each thread finds its position with blockIdx, threadIdx, blockDim, and gridDim. 
// The usual global index is blockIdx.x * blockDim.x + threadIdx.x.
// There's also an optional third and fourth argument: dynamic shared memory bytes and a stream, as in <<<grid, block, smemBytes, stream>>>.
