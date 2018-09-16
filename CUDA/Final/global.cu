#include <stdio.h>
#include <time.h>
#include <math.h>

#define SIZE 150 * 1000

#define THREADS 256 //best value = 256

#define SORT 1
#define TestReduction 0
#define PRINT 1
#define printErrors 1
#define CHECK 1
#define DATATYPE struct number
#define VALUETYPE int
#define RECORDTIME 1
#define MIN INT_MIN

#define OPTION 2
/*
1: i+1 
2: SIZE-i
3: rand() % 100
*/

//#define CUDA_ERROR_CHECK

/* Function declarations */
void getGridComposition(int, unsigned int *, unsigned int *);
void printResults(VALUETYPE *);

/* Struct for not losing the global index */
struct number
{
    VALUETYPE value;
    unsigned int index;
};

/* Error Checking */

#define CudaSafeCall(err) __cudaSafeCall(err, __FILE__, __LINE__)
#define CudaCheckError() __cudaCheckError(__FILE__, __LINE__)

inline void __cudaSafeCall(cudaError err, const char *file, const int line)
{
#ifdef CUDA_ERROR_CHECK
    if (cudaSuccess != err)
    {
        fprintf(stderr, "cudaSafeCall() failed at %s:%i : %s\n", file, line, cudaGetErrorString(err));
        exit(-1);
    }
#endif
    return;
}

inline void __cudaCheckError(const char *file, const int line)
{
#ifdef CUDA_ERROR_CHECK
    cudaError err = cudaGetLastError();
    if (cudaSuccess != err)
    {
        fprintf(stderr, "cudaCheckError() failed at %s:%i : %s\n", file, line, cudaGetErrorString(err));
        exit(-1);
    }

    /* Can affect performance. Comment if needed. */
    err = cudaDeviceSynchronize();
    if (cudaSuccess != err)
    {
        fprintf(stderr, "cudaCheckError() with sync failed at %s:%i : %s\n", file, line, cudaGetErrorString(err));
        exit(-1);
    }
#endif
    return;
}

__global__ void loadKernel(int size, DATATYPE * g_list, DATATYPE * g_loadto){
    unsigned int tid = threadIdx.x;
    unsigned int gid = (blockIdx.x * blockDim.x) + tid;

    if(gid < size){
        g_loadto[gid] = g_list[gid];
    }
}
/* Kernel reduction at block level */
/* One thread per data */
__global__ void reduceKernel(int size, DATATYPE *g_input, DATATYPE *g_output)
{

    unsigned int tid = threadIdx.x;
    unsigned int gid = (blockIdx.x * blockDim.x) + tid;

    for (unsigned int s = blockDim.x / 2; s > 0; s >>= 1)
    {
        if (tid < s)
        {
            if (gid + s < size)
                g_input[gid] = g_input[gid].value > g_input[gid + s].value ? g_input[gid] : g_input[gid + s];
        }
        __syncthreads();
    }

    if (tid == 0)
        g_output[blockIdx.x] = g_input[gid];
}

/* This function swaps the MAX element [which should be in position 0] with the last element of the list */
/* WARNING: This function must be called by only one block */
__global__ void swapKernel(int size, DATATYPE *g_list, DATATYPE *g_max)
{
    DATATYPE max;
    DATATYPE last_element;
    unsigned int index;

    max = g_max[0];
    last_element = g_list[size - 1];

    index = max.index;
    max.index = size - 1;
    last_element.index = index;

    g_list[index] = last_element; /* Donde estaba el valor maximo, pongo el ultimo elemento de la lista */
    g_list[size - 1] = max;     /* Al maximo lo pongo al final de la lista */
    
}

/* Kernel call that wraps data into a struct with index */
__global__ void wrapKernel(int size, DATATYPE *g_wrapped_list, VALUETYPE *g_list)
{
    unsigned int gid = threadIdx.x + blockDim.x * blockIdx.x;
    DATATYPE myData;

    if (gid < size)
    {
        myData.value = g_list[gid];
        myData.index = gid;
        g_wrapped_list[gid] = myData;
    }
}

/* Kernel call that unwraps data into an array of VALUETYPE */
__global__ void unwrapKernel(int size, DATATYPE *g_wrapped_list, VALUETYPE *g_list)
{
    unsigned int gid = threadIdx.x + blockDim.x * blockIdx.x;

    if (gid < size)
    {
        g_list[gid] = g_wrapped_list[gid].value;
    }
}

/* Wraps Reduction Kernel Call */
DATATYPE * reduceMax(int size, DATATYPE *g_list, DATATYPE *g_wa, DATATYPE *g_wb)
{

    unsigned int threads, blocks;
    DATATYPE *input, *output, *ptr;

    int N, temp;
    dim3 dimGrid(1, 1, 1);
    dim3 dimBlock(1, 1, 1);

    getGridComposition(size, &blocks, &threads);
    dimGrid.x = blocks;
    dimBlock.x = threads;

    N = size;

    input = g_wa;
    output = g_wb;

    loadKernel<<<dimGrid, dimBlock>>>(N, g_list, input);

    while (dimGrid.x > 0)
    {
        //printf("Bloques: %d, N: %d\n", dimGrid.x, N);
        reduceKernel<<<dimGrid, dimBlock>>>(N, input, output);
        CudaCheckError();

        temp = (N / dimBlock.x);
        if (N % (dimBlock.x) != 0)
            temp++;
        N = temp;
        
        ptr = input;
        input = output;
        output = ptr;

        if (dimGrid.x == 1)
            dimGrid.x = 0;
        else
            dimGrid.x = dimGrid.x > dimBlock.x ? dimGrid.x / dimBlock.x : 1;
    }

    return input; /* At this point input is the last output */
}

/* Calls the iterative reduction wrapper and sorts the max results */
void sortBySelectionIterative(int size, DATATYPE *g_wlist, DATATYPE *g_wa, DATATYPE *g_wb)
{
    DATATYPE * result;
    for (int i = size; i > 1; i--)
    {
        result = reduceMax(i, g_wlist, g_wa, g_wb);
        swapKernel<<<1, 1>>>(i, g_wlist, result);

        /* Test */
        /*
        unwrapKernel<<<1, 256>>>(SIZE, g_list, g_test_list);
        CudaCheckError();
        CudaSafeCall(cudaMemcpy(test_list, g_list, SIZE * sizeof(VALUETYPE), cudaMemcpyDeviceToHost));
        printResults(test_list);
        */

    }

    return;
}

/* Get the number of blocks and threads per block */
void getGridComposition(int size, unsigned int *blocks, unsigned int *threads)
{

    *threads = THREADS;
    *blocks = 1;

    while (((*blocks) * (*threads)) < size)
    {
        *blocks <<= 1;
    }

    return;
}

void printResults(VALUETYPE *sorted_list)
{
    if (printErrors)
    {
        for (int i = 0; i < SIZE; i++)
        {
            if (sorted_list[i] != (i + 1))
                printf("%d: %d \n", i + 1, sorted_list[i]);
        }
        printf("\n");
    }
    else
    {
        for (int i = 0; i < SIZE; i++)
        {
            printf("%d\n", sorted_list[i]);
        }
        printf("\n");
    }

    return;
}

int checkResults(VALUETYPE *sorted_list)
{
    unsigned int check = 1;
    unsigned int i;
    for (i = 0; i < SIZE; i++)
    {
        if (sorted_list[i] != (i + 1))
            check = 0;
    }

    if (check)
        printf("Resultados correctos!\n");
    else
        printf("Resultados incorrectos!\n");

    return check;
}

int main(void)
{
    printf("SIZE: %d\n", SIZE);
    DATATYPE *g_wlist, *g_wa, *g_wb;
    VALUETYPE *list, *g_list;

    srand(time(NULL));
    /* Allocate Host memory */
    list = (VALUETYPE *)malloc(SIZE * sizeof(VALUETYPE));
    if (list == NULL)
    {
        printf("Error alocando memoria.\n");
        exit(-1);
    }

    /* Allocate device memory */
    CudaSafeCall(cudaMalloc((void **)&g_list, SIZE * sizeof(VALUETYPE)));
    CudaSafeCall(cudaMalloc((void **)&g_wlist, SIZE * sizeof(DATATYPE)));
    CudaSafeCall( cudaMalloc((void**)&g_wa, SIZE  * sizeof(DATATYPE) ) );

    CudaSafeCall( cudaMalloc((void**)&g_wb, (SIZE / THREADS + 1)  * sizeof(DATATYPE) ) );

    /* Initialize data */
    for (int i = 0; i < SIZE; i++)
    {
        switch (OPTION)
        {
        case 1:
            list[i] = i + 1;
            break;
        case 2:
            list[i] = SIZE - i;
            break;
        case 3:
            list[i] = rand() % 100;
            break;
        }        
    }

    /* Wrap Data into a struct with index for sorting */
    unsigned int threads, blocks;
    dim3 dimGrid(1, 1, 1);
    dim3 dimBlock(1, 1, 1);

    CudaSafeCall( cudaMemcpy(g_list, list, SIZE * sizeof(VALUETYPE), cudaMemcpyHostToDevice) );

    getGridComposition(SIZE, &blocks, &threads);
    dimGrid.x = blocks;
    dimBlock.x = threads;

    wrapKernel<<<dimGrid, dimBlock>>>(SIZE, g_wlist, g_list );
    CudaCheckError();
    /* End of wrapping data */


    if (SORT){
        /* Record time */
        cudaEvent_t start, stop;
        if (RECORDTIME)
        {
            cudaEventCreate(&start);
            cudaEventCreate(&stop);
            cudaEventRecord(start);
        }
        sortBySelectionIterative(SIZE, g_wlist, g_wa, g_wb);
        unwrapKernel<<<dimGrid, dimBlock>>>(SIZE, g_wlist, g_list);
        if (RECORDTIME)
        {
            cudaEventRecord(stop);
            cudaEventSynchronize(stop);
            float milliseconds = 0;
            cudaEventElapsedTime(&milliseconds, start, stop);
            printf("Pasaron %f milisegundos\n", milliseconds);
        }

        CudaCheckError();
        CudaSafeCall(cudaMemcpy(list, g_list, SIZE * sizeof(VALUETYPE), cudaMemcpyDeviceToHost));
    } 

    if (TestReduction){
        /* Record time */
        cudaEvent_t start, stop;
        if (RECORDTIME)
        {
            cudaEventCreate(&start);
            cudaEventCreate(&stop);
            cudaEventRecord(start);
        }

        reduceMax(SIZE, g_wlist, g_wa, g_wb);

        if (RECORDTIME)
        {
            cudaEventRecord(stop);
            cudaEventSynchronize(stop);
            float milliseconds = 0;
            cudaEventElapsedTime(&milliseconds, start, stop);
            printf("Pasaron %f milisegundos\n", milliseconds);
        }

        unwrapKernel<<<1, 1>>>(1, g_wb, g_list);
        CudaCheckError();
        CudaSafeCall(cudaMemcpy(list, g_list, 1 * sizeof(VALUETYPE), cudaMemcpyDeviceToHost));
    } 
    

    if(TestReduction){
        printf("El maximo es %d\n", list[0]);
    }

    if (PRINT && SORT)
    {
        printResults(list);
    }
    if(CHECK && SORT)
    {
        checkResults(list);
    }

    CudaSafeCall ( cudaFree(g_list) );
    CudaSafeCall ( cudaFree(g_wa) );
    CudaSafeCall ( cudaFree(g_wb) );
    CudaSafeCall ( cudaFree(g_wlist) );

    free(list);
}