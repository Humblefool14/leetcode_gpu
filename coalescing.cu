#include <cuda.h>
#include <stdio.h>
#include <cuda_runtime.h>

#define N 100
__global__ void copyDatanoncoalesced(float *in, float *out, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x ;
  if (i < n){
    out[i] = in[(i*2)%n]; 
  }
}

__global__ void copyDatacoalesced(float *in, float* out, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x ;
  if (i < n){
    out[i] = in[i]; 
  }
}

void initializearray(float *a, int n) {
  for(int i =0; i < n; i++){
      a[i] = static_cast<float>(i); 
  }
}

int main()
{
    size_t size = N * sizeof(float);
    int n = N; 
    // Allocate input vectors h_A and h_B in host memory

    float * in;
    float *out; 

    cudaMalloc( &in, n* sizeof(float)); 
    cudaMalloc( &out, n* sizeof(float)); 
    initializearray(in, n); 

    int blocksize = 128; 
    int numBlocks = (n + blocksize-1)/blocksize; 

    copyDatanoncoalesced <<< numBlocks, blocksize>>> (in, out, n); 
    cudaDeviceSynchronize();

    copyDatacoalesced <<< numBlocks, blocksize>>> (in, out, n); 
    cudaDeviceSynchronize();

    cudaFree(in);
    cudaFree(out);
}
