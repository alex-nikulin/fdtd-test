#include <iostream>
#include <string>
#include <cmath>
#include "params.cuh"
#include "fdtd.cuh"
#include "plot.cuh"

__constant__ Params pars;

__host__ void start_fdtd(std::string params_filename) {
    Params pars_h = Params();
    pars_h.init_pars(params_filename);
    std::cout << "initializing memory\n";
    pars_h.init_memory_2d();
    check_err(cudaMemcpyToSymbol(pars, &pars_h, sizeof(Params)), "copying params to device");

    int threadsPerBlock = 8;
    int blocksPerGridX = (pars_h.Nx + threadsPerBlock - 1) / threadsPerBlock;
    int blocksPerGridY = (pars_h.Ny + threadsPerBlock - 1) / threadsPerBlock;
    int blocksPerGridZ = (pars_h.Nz + threadsPerBlock - 1) / threadsPerBlock;

    dim3 blockShape(threadsPerBlock, threadsPerBlock, threadsPerBlock);
    dim3 gridShape(blocksPerGridX, blocksPerGridY, blocksPerGridZ);

    dim3 blockShape2D(threadsPerBlock, threadsPerBlock);
    dim3 gridShape2D(blocksPerGridX, blocksPerGridY);

    auto source { [](int step, Params& pars){return exp(-pow((step-pars.source_offset)*pars.dt/pars.source_width,2));} };
    std::string plots_path = static_cast<std::string>(pars_h.plots_path_cstr);
    plot_funtion(source, pars_h, "source");
    int pml_offset = (2*pars_h.Npx*pars_h.Ny+2*pars_h.Npy*pars_h.Nx-4*pars_h.Npx*pars_h.Npy);
    std::cout << "starting sim\n";

    for (int step = 1; step <= pars_h.n_steps; ++step) {
        check_err(cudaPeekAtLastError(), "kernel");
        check_err(cudaDeviceSynchronize(), "e sync");
        inject_soft_source_2d<<<1,1>>>(pars_h.device.ez, source(step, pars_h));
        check_err(cudaPeekAtLastError(), "kernel");
        check_err(cudaDeviceSynchronize(), "src sync");
        calc_fdtd_step_2d_x<<<gridShape2D,blockShape2D>>>(
            pars_h.device.hx, 
            pars_h.device.ez, 
            pars_h.device.pmlx+pml_offset*6,
            pars_h.device.mu, 
            pars_h.yp
        );
        calc_fdtd_step_2d_y<<<gridShape2D,blockShape2D>>>(
            pars_h.device.hy, 
            pars_h.device.ez, 
            pars_h.device.pmly+pml_offset*6,
            pars_h.device.mu, 
            pars_h.xp
        );
        calc_fdtd_step_2d_z<<<gridShape2D,blockShape2D>>>(
            pars_h.device.hz, 
            pars_h.device.ey, 
            pars_h.device.ex, 
            pars_h.device.pmlz+pml_offset*6,
            pars_h.device.mu, 
            pars_h.xp, 
            pars_h.yp
        );
        check_err(cudaPeekAtLastError(), "kernel");
        check_err(cudaDeviceSynchronize(), "h sync");
        calc_fdtd_step_2d_x<<<gridShape2D,blockShape2D>>>(
            pars_h.device.ex, 
            pars_h.device.hz, 
            pars_h.device.pmlx,
            pars_h.device.eps, 
            pars_h.ym
        );
        calc_fdtd_step_2d_y<<<gridShape2D,blockShape2D>>>(
            pars_h.device.ey, 
            pars_h.device.hz, 
            pars_h.device.pmly,
            pars_h.device.eps, 
            pars_h.xm
        );
        calc_fdtd_step_2d_z<<<gridShape2D,blockShape2D>>>(
            pars_h.device.ez, 
            pars_h.device.hy, 
            pars_h.device.hx, 
            pars_h.device.pmlz,
            pars_h.device.eps, 
            pars_h.xm, 
            pars_h.ym
        );

        if (step%pars_h.drop_rate == 0) {
            pars_h.extract_data_2d();
            std::cout << "step " << step << ", dt: " << pars_h.dt << ", dr = " << pars_h.dr;
            plot(pars_h.host.ez, pars_h, "ez", step);
        }
    }
    pars_h.free_memory();
}

__host__ int main(int argc, char *argv[]) {
    if (argc <= 1) {
        std::cout << "Please, specify a .json file with simulation parameters\n";
        return 1;
    }
    try {
        start_fdtd(argv[1]);
        std::cout << "Test run complete!\n";
    }
    catch (const std::string& message) {
        std::cout << message << std::endl;
    }    

    return 0;
}