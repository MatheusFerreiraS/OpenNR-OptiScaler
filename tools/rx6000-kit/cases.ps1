# What the RX 6000 kit runs (kit.ps1 and make-refs.ps1 read this).
# Quality: clean runs (NR_DIAG_SEED0=1, NR_DIAG_TGATE0=1: noise seed 0, no history), so every frame is the same work
# and the output does not depend on the frame times; each against the RX 9070 XT FP8 network's clean output.
$Quality = @(
    @{ name = 'small_1152x648'; model = 'small'; w = 1152; h = 648 },
    @{ name = 'small_1280x720'; model = 'small'; w = 1280; h = 720 },
    @{ name = 'small_1506x847'; model = 'small'; w = 1506; h = 847 },
    @{ name = 'small_1920x1080'; model = 'small'; w = 1920; h = 1080 },
    @{ name = 'small_2560x1440'; model = 'small'; w = 2560; h = 1440 },
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
# Candidate sets (kit.ps1 stage 6): each files\variant\<name> holds the files the sets differ in, built one way (one of
# them the shipped set's, $MainSet), each with its own SPIR-V generator word so that no driver cache holds them. Each is
# compiled cold by the runtime's own check and built, its picture must be IDENTICAL to stage 4's, and the steps of
# $VariantCases are timed $CandidateRounds times, the sets alternating. The pick: the fastest (sum of those steps), or
# among the sets within $PickWithin of it the one whose files the check compiled quickest.
$MainSet = @{ name = 'rolled'; about = 'pass 1 of the Swin attention rolled: one copy of the logits, a 32-entry queue (the shipped set)' }
$VariantCases = @('small_1280x720', 'large_1280x720')
$CandidateRounds = 2
$PickWithin = 0.01
