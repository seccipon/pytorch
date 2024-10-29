#define TORCH_ASSERT_ONLY_METHOD_OPERATORS
#include <ATen/Dispatch.h>
#include <ATen/core/Tensor.h>
#include <ATen/cuda/CUDAContext.h>
#include <ATen/cuda/nvrtc_stub/ATenNVRTC.h>

// We are going to override the cuTensorMapEncodeTiled driver api with our lazy
// loader
static CUresult CUDAAPI nvrtc_cuTensorMapEncodeTiled(
    CUtensorMap* tensorMap,
    CUtensorMapDataType tensorDataType,
    cuuint32_t tensorRank,
    void* globalAddress,
    const cuuint64_t* globalDim,
    const cuuint64_t* globalStrides,
    const cuuint32_t* boxDim,
    const cuuint32_t* elementStrides,
    CUtensorMapInterleave interleave,
    CUtensorMapSwizzle swizzle,
    CUtensorMapL2promotion l2Promotion,
    CUtensorMapFloatOOBfill oobFill) {
  return at::globalContext().getNVRTC().cuTensorMapEncodeTiled(
      tensorMap,
      tensorDataType,
      tensorRank,
      globalAddress,
      globalDim,
      globalStrides,
      boxDim,
      elementStrides,
      interleave,
      swizzle,
      l2Promotion,
      oobFill);
}

// clang-format off
#include <cutlass/core_io.h>
#include <cutlass/cutlass.h>
#include <cutlass/gemm/device/gemm.h>
#include <cutlass/half.h>
#include <cutlass/numeric_types.h>
#include <cutlass/trace.h>
#include <cutlass/util/host_tensor.h>

// Rename the global function symbol
#define cuTensorMapEncodeTiled nvrtc_cuTensorMapEncodeTiled
#include <cute/tensor.hpp>
#undef cuTensorMapEncodeTiled
// Set everything back to normal

#include <cutlass/gemm/collective/collective_builder.hpp>
#include <cutlass/gemm/device/gemm_universal_adapter.h>
#include <cutlass/epilogue/collective/collective_builder.hpp>

#include <cute/atom/mma_atom.hpp>
#include <cutlass/gemm/dispatch_policy.hpp>
#include <cutlass/gemm/kernel/gemm_universal.hpp>
#include <cutlass/util/packed_stride.hpp>
// clang-format on

#include <torch/csrc/distributed/c10d/cuda/cutlass/gemm/kernel/persistent_async_input_scheduler.cuh>

namespace {

using namespace cute;

template <typename TileShape_MNK, typename ClusterShape_MNK>
at::Tensor async_input_mm_impl(
    at::Tensor a,
    at::Tensor b,
    at::Tensor a_chunk_signals,
    int64_t a_chunk_pivot,
    at::Tensor out) {
  using ElementA = cutlass::bfloat16_t;
  using LayoutA = cutlass::layout::RowMajor;
  constexpr int AlignmentA = 128 / cutlass::sizeof_bits<ElementA>::value;

  using ElementB = cutlass::bfloat16_t;
  using LayoutB = cutlass::layout::ColumnMajor;
  constexpr int AlignmentB = 128 / cutlass::sizeof_bits<ElementB>::value;

  using ElementC = cutlass::bfloat16_t;
  using LayoutC = cutlass::layout::RowMajor;
  constexpr int AlignmentC = 128 / cutlass::sizeof_bits<ElementC>::value;

  using ElementAccumulator = float;

  using KernelSchedule = cutlass::gemm::KernelTmaWarpSpecializedCooperative;
  using EpilogueSchedule = cutlass::epilogue::TmaWarpSpecializedCooperative;

  using CollectiveEpilogue =
      typename cutlass::epilogue::collective::CollectiveBuilder<
          cutlass::arch::Sm90,
          cutlass::arch::OpClassTensorOp,
          TileShape_MNK,
          ClusterShape_MNK,
          cutlass::epilogue::collective::EpilogueTileAuto,
          ElementAccumulator,
          ElementAccumulator,
          void,
          LayoutC,
          AlignmentC,
          ElementC,
          LayoutC,
          AlignmentC,
          EpilogueSchedule>::CollectiveOp;

  using CollectiveMainloop =
      typename cutlass::gemm::collective::CollectiveBuilder<
          cutlass::arch::Sm90,
          cutlass::arch::OpClassTensorOp,
          ElementA,
          LayoutA,
          AlignmentA,
          ElementB,
          LayoutB,
          AlignmentB,
          ElementAccumulator,
          TileShape_MNK,
          ClusterShape_MNK,
          cutlass::gemm::collective::StageCountAutoCarveout<static_cast<int>(
              sizeof(typename CollectiveEpilogue::SharedStorage))>,
          KernelSchedule>::CollectiveOp;

  using GemmKernel = cutlass::gemm::kernel::GemmUniversal<
      Shape<int, int, int, int>,
      CollectiveMainloop,
      CollectiveEpilogue,
      cutlass::gemm::PersistentAsyncInputScheduler<KernelSchedule>>;
  using Gemm = cutlass::gemm::device::GemmUniversalAdapter<GemmKernel>;

  using StrideA = typename Gemm::GemmKernel::StrideA;
  using StrideB = typename Gemm::GemmKernel::StrideB;
  using StrideC = typename Gemm::GemmKernel::StrideC;

  TORCH_CHECK(a.is_contiguous());
  TORCH_CHECK(b.stride(1) == b.size(0));
  TORCH_CHECK(b.stride(0) == 1);
  TORCH_CHECK_EQ(a.scalar_type(), at::kBFloat16);
  TORCH_CHECK_EQ(b.scalar_type(), at::kBFloat16);

  int M = static_cast<int>(a.sizes()[0]);
  int N = static_cast<int>(b.sizes()[1]);
  int K = static_cast<int>(a.sizes()[1]);
  TORCH_CHECK_EQ(b.sizes()[0], K);
  TORCH_CHECK_EQ(out.sizes()[0], M);
  TORCH_CHECK_EQ(out.sizes()[1], N);

  auto stride_A = cutlass::make_cute_packed_stride(StrideA{}, {M, K, 1});
  auto stride_B = cutlass::make_cute_packed_stride(StrideB{}, {N, K, 1});
  auto stride_C = cutlass::make_cute_packed_stride(StrideC{}, {M, N, 1});

  Gemm gemm;

  typename Gemm::Arguments arguments{
      cutlass::gemm::GemmUniversalMode::kGemm,
      {M, N, K, 1},
      {
          reinterpret_cast<ElementA*>(a.data_ptr<at::BFloat16>()),
          stride_A,
          reinterpret_cast<ElementB*>(b.data_ptr<at::BFloat16>()),
          stride_B,
      },
      {{1, 1},
       nullptr,
       stride_C,
       reinterpret_cast<ElementC*>(out.data_ptr<at::BFloat16>()),
       stride_C},
  };

  TORCH_CHECK(a_chunk_signals.sizes().size() == 1);
  size_t num_chunks_M = a_chunk_signals.numel();

  TORCH_CHECK(M % num_chunks_M == 0);
  size_t chunk_size_M = M / num_chunks_M;
  size_t tile_size_M = cute::get<0>(TileShape_MNK{});

  TORCH_CHECK(chunk_size_M % tile_size_M == 0);

  using RasterOrderOptions = typename cutlass::gemm::kernel::detail::
      PersistentTileSchedulerSm90::RasterOrderOptions;
  arguments.scheduler.max_swizzle_size = chunk_size_M / tile_size_M;
  arguments.scheduler.raster_order = RasterOrderOptions::AlongN;
  arguments.scheduler.tile_idx_pivot_m = 0 * (chunk_size_M / tile_size_M);
  arguments.scheduler.tiles_per_chunk_m = chunk_size_M / tile_size_M;
  arguments.scheduler.chunk_signals = a_chunk_signals.data_ptr<uint32_t>();

  size_t workspace_size = Gemm::get_workspace_size(arguments);
  cutlass::device_memory::allocation<uint8_t> workspace(workspace_size);

  TORCH_CHECK(gemm.can_implement(arguments) == cutlass::Status::kSuccess);
  TORCH_CHECK(
      gemm.initialize(arguments, workspace.get()) == cutlass::Status::kSuccess);
  TORCH_CHECK(
      gemm(at::cuda::getCurrentCUDAStream()) == cutlass::Status::kSuccess);

  C10_CUDA_KERNEL_LAUNCH_CHECK();
  return out;
}

} // namespace

namespace c10d::symmetric_memory::cuda {

at::Tensor async_input_mm_out(
    at::Tensor a,
    at::Tensor b,
    at::Tensor a_chunk_signals,
    int64_t a_chunk_pivot,
    at::Tensor out) {
  TORCH_CHECK(a.is_contiguous());
  TORCH_CHECK(b.stride(1) == b.size(0));
  TORCH_CHECK(b.stride(0) == 1);
  TORCH_CHECK_EQ(a.scalar_type(), at::kBFloat16);
  TORCH_CHECK_EQ(b.scalar_type(), at::kBFloat16);

  int64_t M = a.sizes()[0];
  int64_t N = b.sizes()[1];
  int64_t K = a.sizes()[1];
  TORCH_CHECK_EQ(b.sizes()[0], K);
  TORCH_CHECK_EQ(out.sizes()[0], M);
  TORCH_CHECK_EQ(out.sizes()[1], N);

  return async_input_mm_impl<cute::Shape<_128, _256, _64>, Shape<_1, _2, _1>>(
      a, b, a_chunk_signals, a_chunk_pivot, out);
}

at::Tensor async_input_mm(
    at::Tensor a,
    at::Tensor b,
    at::Tensor a_chunk_signals,
    int64_t a_chunk_pivot) {
  TORCH_CHECK(a.is_contiguous());
  TORCH_CHECK(b.stride(1) == b.size(0));
  TORCH_CHECK(b.stride(0) == 1);
  TORCH_CHECK_EQ(a.scalar_type(), at::kBFloat16);
  TORCH_CHECK_EQ(b.scalar_type(), at::kBFloat16);

  int64_t M = a.sizes()[0];
  int64_t N = b.sizes()[1];
  int64_t K = a.sizes()[1];
  TORCH_CHECK_EQ(b.sizes()[0], K);

  auto out = a.new_empty({M, N});
  return async_input_mm_out(a, b, a_chunk_signals, a_chunk_pivot, out);
}

} // namespace c10d::symmetric_memory::cuda