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
$Steps = @('small_1280x720', 'small_1920x1080', 'large_1280x720')
$StepFrames = 30
$StepCount = 20
# Variants (files\variant\<name>, kit.ps1 stage 6): one clean run and the steps of these cases each.
$VariantCases = @('small_1280x720', 'large_1280x720')
