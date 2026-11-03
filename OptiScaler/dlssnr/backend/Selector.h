#pragma once
#include "Kind.h"

namespace DlssNr::Backend
{
Kind RequestedKind();
Kind ActiveKindFromConfig();
// True while lmxxf (with LmxxfWired()) or mochizuki is active, or OpenRR was enabled at launch. Mutual exclusion
// vs graphics tracker.
bool SubmissionHooksWanted();
// The runtimes NR without upscaling runs on: danielblnc, and mochizuki between two lists of its own.
bool PresentRuntimeSupported();
} // namespace DlssNr::Backend
