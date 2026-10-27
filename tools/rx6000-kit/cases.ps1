# What the RX 6000 kit runs (kit.ps1 and make-refs.ps1 read this).
# Quality: clean runs (NR_DIAG_SEED0=1, NR_DIAG_TGATE0=1: noise seed 0, no history), so every frame is the same work
# and the output does not depend on the frame times; each against the RX 9070 XT FP8 network's clean output.
$Quality = @(
    @{ name = 'small_1280x720'; model = 'small'; w = 1280; h = 720 },
    @{ name = 'small_1920x1080'; model = 'small'; w = 1920; h = 1080 },
    @{ name = 'large_1280x720'; model = 'large'; w = 1280; h = 720 })
$QualityFrames = 8
$QualityRuns = 3
$PassDb = 40.0
$Clean = @{ NR_DIAG_SEED0 = '1'; NR_DIAG_TGATE0 = '1' }
# Speed: normal runs (as in a game), the network time from the status line; then NR_STEP_TIMES per pipeline.
$Speed = @(
    @{ name = 'small_1280x720'; model = 'small'; w = 1280; h = 720 },
    @{ name = 'small_1920x1080'; model = 'small'; w = 1920; h = 1080 },
    @{ name = 'large_1280x720'; model = 'large'; w = 1280; h = 720 })
$SpeedFrames = 40
$Steps = @('small_1280x720', 'small_1920x1080')
$StepFrames = 30
$StepCount = 20
# Pipelines shipped in shaders-rdna2 that neither model dispatches at 720p-1440p and that are still emulated (the
# non-persistent downsample: 42-260 s each on the RX 9070 XT; on the gfx1030 null device of driver .342 the 128 and 256
# ones did not compile at all). The kit's own compile stage leaves them out; the runtime's pipeline check compiles them
# in the first run (8 threads, as in a game), and when it refuses one the runs go on without it (MZ_RDNA2_CHECK=0).
$Unused = @('g_fswinds32.spv', 'g_fswinds64.spv', 'g_fswinds128.spv', 'g_fswinds256.spv')
# Native against emulated (layer A): the emulated kernels of the pipelines the small model dispatches at 720p
# (files\emulated), swapped in for the native ones wherever the driver compiles them in time; the output must stay
# byte for byte the same.
$Emulated = 'small_1280x720'
