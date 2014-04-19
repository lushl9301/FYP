#pragma once
#include <gunrock/util/basic_utils.cuh>
#include <gunrock/util/cuda_properties.cuh>
#include <gunrock/util/cta_work_distribution.cuh>
#include <gunrock/util/soa_tuple.cuh>
#include <gunrock/util/srts_grid.cuh>
#include <gunrock/util/srts_soa_details.cuh>
#include <gunrock/util/io/modified_load.cuh>
#include <gunrock/util/io/modified_store.cuh>
#include <gunrock/util/operators.cuh>

#include <gunrock/app/problem_base.cuh>
#include <gunrock/app/enactor_base.cuh>

#include <gunrock/util/cta_work_distribution.cuh>
#include <gunrock/util/cta_work_progress.cuh>
#include <gunrock/util/kernel_runtime_stats.cuh>

#include <gunrock/oprtr/edge_map_forward/kernel.cuh>
#include <gunrock/oprtr/edge_map_backward/kernel.cuh>
#include <gunrock/oprtr/edge_map_partitioned/kernel.cuh>

#include <gunrock/oprtr/advance/kernel_policy.cuh>

#include <moderngpu.cuh>

namespace gunrock {
namespace oprtr {
namespace advance {

//TODO: finish LaucnKernel, should load diferent kernels according to their AdvanceMode
//AdvanceType is the argument to send into each kernel call
template <typename KernelPolicy, typename ProblemData, typename Functor>
    void LaunchKernel(
            volatile int                            *d_done,
            gunrock::app::EnactorStats              &enactor_stats,
            gunrock::app::FrontierAttribute         &frontier_attribute,
            typename ProblemData::DataSlice         *data_slice,
            typename ProblemData::VertexId          *backward_index_queue,
            bool                                    *backward_frontier_map_in,
            bool                                    *backward_frontier_map_out,
            unsigned int                            *partitioned_scanned_edges,
            typename KernelPolicy::VertexId         *d_in_key_queue,
            typename KernelPolicy::VertexId         *d_out_key_queue,
            typename KernelPolicy::VertexId         *d_in_value_queue,
            typename KernelPolicy::VertexId         *d_out_value_queue,
            typename KernelPolicy::SizeT            *d_row_offsets,
            typename KernelPolicy::VertexId         *d_column_indices,
            typename KernelPolicy::SizeT            *d_column_offsets,
            typename KernelPolicy::VertexId         *d_row_indices,
            typename KernelPolicy::SizeT            max_in,
            typename KernelPolicy::SizeT            max_out,
            util::CtaWorkProgress                   work_progress,
            CudaContext                             &context,
            TYPE                      ADVANCE_TYPE)

{
            
    switch (KernelPolicy::ADVANCE_MODE)
    {
        case TWC_FORWARD:
        {
            printf("before kernel.\n");
            // Load Thread Warp CTA Forward Kernel
            gunrock::oprtr::edge_map_forward::Kernel<typename KernelPolicy::THREAD_WARP_CTA_FORWARD, ProblemData, Functor>
                <<<enactor_stats.advance_grid_size, KernelPolicy::THREAD_WARP_CTA_FORWARD::THREADS>>>(
                    frontier_attribute.queue_reset,
                    frontier_attribute.queue_index,
                    enactor_stats.num_gpus,
                    enactor_stats.iteration,
                    frontier_attribute.queue_length,
                    d_done,
                    d_in_key_queue,              // d_in_queue
                    d_out_value_queue,          // d_pred_out_queue
                    d_out_key_queue,            // d_out_queue
                    d_column_indices,
                    data_slice,
                    work_progress,
                    max_in,                   // max_in_queue
                    max_out,                 // max_out_queue
                    enactor_stats.advance_kernel_stats,
                    ADVANCE_TYPE);
            break;
        }
        case TWC_BACKWARD:
        {
            // Load Thread Warp CTA Backward Kernel
            if (frontier_attribute.selector == 1) {
                // Edge Map
                gunrock::oprtr::edge_map_backward::Kernel<typename KernelPolicy::THREAD_WARP_CTA_BACKWARD, ProblemData, Functor>
                    <<<enactor_stats.advance_grid_size, KernelPolicy::THREAD_WARP_CTA_BACKWARD::THREADS>>>(
                            frontier_attribute.queue_reset,
                            frontier_attribute.queue_index,
                            enactor_stats.num_gpus,
                            frontier_attribute.queue_length,
                            enactor_stats.d_done,
                            d_in_key_queue,              // d_in_queue
                            backward_index_queue,            // d_in_index_queue
                            backward_frontier_map_in,
                            backward_frontier_map_out,
                            d_column_offsets,
                            d_row_indices,
                            data_slice,
                            work_progress,
                            enactor_stats.advance_kernel_stats,
                            ADVANCE_TYPE);
            } else {
                // Edge Map
                gunrock::oprtr::edge_map_backward::Kernel<typename KernelPolicy::THREAD_WARP_CTA_BACKWARD, ProblemData, Functor>
                    <<<enactor_stats.advance_grid_size, KernelPolicy::THREAD_WARP_CTA_BACKWARD::THREADS>>>(
                            frontier_attribute.queue_reset,
                            frontier_attribute.queue_index,
                            enactor_stats.num_gpus,
                            frontier_attribute.queue_length,
                            enactor_stats.d_done,
                            d_in_key_queue,              // d_in_queue
                            backward_index_queue,            // d_in_index_queue
                            backward_frontier_map_out,
                            backward_frontier_map_in,
                            d_column_offsets,
                            d_row_indices,
                            data_slice,
                            work_progress,
                            enactor_stats.advance_kernel_stats,
                            ADVANCE_TYPE);
            }
            break;
        }
        case LB:
        {
            typedef typename ProblemData::SizeT         SizeT;
            typedef typename ProblemData::VertexId      VertexId;
            // Load Load Balanced Kernel
            // Get Rowoffsets
            // Use scan to compute edge_offsets for each vertex in the frontier
            // Use sorted sort to compute partition bound for each work-chunk
            // load edge-expand-partitioned kernel
            int num_block = (frontier_attribute.queue_length + KernelPolicy::LOAD_BALANCED::THREADS - 1)/KernelPolicy::LOAD_BALANCED::THREADS;
            gunrock::oprtr::edge_map_partitioned::GetEdgeCounts<typename KernelPolicy::LOAD_BALANCED, ProblemData, Functor>
            <<< num_block, KernelPolicy::LOAD_BALANCED::THREADS >>>(
                                        d_row_offsets,
                                        d_in_key_queue,
                                        partitioned_scanned_edges,
                                        frontier_attribute.queue_length,
                                        max_in,
                                        max_out);

            Scan<mgpu::MgpuScanTypeInc>((int*)partitioned_scanned_edges, frontier_attribute.queue_length, (int)0, mgpu::plus<int>(),
            (int*)0, (int*)0, (int*)partitioned_scanned_edges, context);

            SizeT *temp = new SizeT[1];
            cudaMemcpy(temp,partitioned_scanned_edges+frontier_attribute.queue_length-1, sizeof(SizeT), cudaMemcpyDeviceToHost);
            SizeT output_queue_len = temp[0];

            //if (output_queue_len < EdgeMapPolicy::LIGHT_EDGE_THRESHOLD)
            {
                gunrock::oprtr::edge_map_partitioned::RelaxLightEdges<typename KernelPolicy::LOAD_BALANCED, ProblemData, Functor>
                <<< num_block, KernelPolicy::LOAD_BALANCED::THREADS >>>(
                        frontier_attribute.queue_reset,
                        frontier_attribute.queue_index,
                        enactor_stats.iteration,
                        d_row_offsets,
                        d_column_indices,
                        partitioned_scanned_edges,
                        enactor_stats.d_done,
                        d_in_key_queue,
                        d_out_key_queue,
                        data_slice,
                        frontier_attribute.queue_length,
                        output_queue_len,
                        max_in,
                        max_out,
                        work_progress,
                        enactor_stats.advance_kernel_stats,
                        ADVANCE_TYPE);
            }
            //else
            /*{
                unsigned int split_val = (output_queue_len + KernelPolicy::LOAD_BALANCED::BLOCKS - 1) / KernelPolicy::LOAD_BALANCED::BLOCKS;
                util::MemsetIdxKernel<<<128, 128>>>(enactor_stats.d_node_locks, KernelPolicy::LOAD_BALANCED::BLOCKS, split_val);
                SortedSearch<MgpuBoundsLower>(
                enactor_stats.d_node_locks,
                KernelPolicy::LOAD_BALANCED::BLOCKS,
                partitioned_scanned_edges,
                frontier_attribute.queue_length,
                enactor_stats.d_node_locks_out,
                enactor_stats.context);

                gunrock::oprtr::edge_map_partitioned::RelaxPartitionedEdges<KernelPolicy::LOAD_BALANCED, ProblemData, Functor>
                <<< KernelPolicy::LOAD_BALANCED::BLOCKS, KernelPolicy::LOAD_BALANCED::THREADS >>>(
                                        frontier_attribute.queue_reset,
                                        frontier_attribute.queue_index,
                                        enactor_stats.iteration,
                                        d_row_offsets,
                                        d_column_indices,
                                        partitioned_scanned_edges,
                                        enactor_stats.d_node_locks_out,
                                        KernelPolicy::LOAD_BALANCED::BLOCKS,
                                        enactor_stats.d_done,
                                        d_in_key_queue,
                                        d_out_key_queue,
                                        data_slice,
                                        frontier_attribute.queue_length,
                                        output_queue_len,
                                        split_val,
                                        max_in,
                                        max_out,
                                        work_progress,
                                        enactor_stats.advance_kernel_stats,
                                        ADVANCE_TYPE);
            }*/
            break;
        }
    }
}


} //advance
} //oprtr
} //gunrock/
