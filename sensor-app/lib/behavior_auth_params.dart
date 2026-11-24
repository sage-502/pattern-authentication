// Legacy touch-window compatibility parameters.

const behaviorPipelineVersion = 'touch_v3';
const behaviorSeqLen = 48;
const behaviorDtwBand = 8;
const behaviorDtwK = 5;
const behaviorTimingFloor = 0.05;
const behaviorMadToSigma = 1.4826;
const behaviorMinRows = 5;
const behaviorThreshold = -2.1788287115882596;

/// Per-channel (ax, ay, az, gx, gy, gz) mean and std of the resampled research
/// sequences; used to standardise motion sequences before DTW.
const behaviorSeqMean = <double>[-2.6656560575365544, 3.138047543671447, 8.2753821717363, -0.08164912306143805, -0.3443050275210067, -0.12467444263752604];
const behaviorSeqStd = <double>[2.7221641467422906, 1.8220543209566031, 1.2852984297998378, 0.4616845620562387, 1.0847298986543865, 0.2726802039753251];
