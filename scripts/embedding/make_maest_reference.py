"""Write the reference data liborca's MAEST embedding tests compare against.

Usage: make_maest_reference.py MODEL OUTDIR

MODEL is the maest_audio_int8.onnx that export_maest.py writes. For each test
signal, generated at 16 kHz, OUTDIR receives NAME_maest_mel_frames.f32, the
mel frames 0, 1, 2, 313, 623, 624 and 625 of the normalised 626-frame
spectrogram as 7 x 96 little-endian float32, and NAME_maest_emb_int8.f32, the
model's 768 output values for the whole spectrogram.

The front end follows the model's published recipe and is built from
transformers.audio_utils: FFT 512, hop 256, centred with zero padding,
periodic Hann window, power 2, 96 Slaney mel bands over 0-8000 Hz,
log10(1 + 10000 x), truncation or zero padding to 626 frames, then
(x - mean) / (2 * deviation).
"""

import sys
from pathlib import Path

import numpy as np
import onnxruntime
from transformers.audio_utils import mel_filter_bank, spectrogram, window_function

SAMPLE_RATE = 16_000
FFT_SIZE = 512
HOP_SIZE = 256
BAND_COUNT = 96
FRAME_COUNT = 626
LOG_SCALE = 10_000.0
NORMALISATION_MEAN = 2.06755686098554
NORMALISATION_DEVIATION = 1.268292820667291
STORED_FRAMES = [0, 1, 2, 313, 623, 624, 625]
SIGNAL_SECONDS = {"sine440": 10, "chirp": 10, "mix": 10, "sine440_3s": 3}


def signal(name: str) -> np.ndarray:
    time = np.arange(SIGNAL_SECONDS[name] * SAMPLE_RATE, dtype=np.float64) / SAMPLE_RATE
    if name == "chirp":
        samples = 0.5 * np.sin(2 * np.pi * (100 * time + 595.0 * time * time))
    elif name == "mix":
        envelope = 0.5 * (1 - np.cos(2 * np.pi * 2 * time))
        samples = envelope * sum(
            0.2 * np.sin(2 * np.pi * hz * time) for hz in (220, 880, 3520, 9000)
        )
    else:
        samples = 0.5 * np.sin(2 * np.pi * 440 * time)
    return samples.astype(np.float32)


def normalised_mel(samples: np.ndarray) -> np.ndarray:
    filters = mel_filter_bank(
        num_frequency_bins=FFT_SIZE // 2 + 1,
        num_mel_filters=BAND_COUNT,
        min_frequency=0.0,
        max_frequency=SAMPLE_RATE / 2,
        sampling_rate=SAMPLE_RATE,
        norm="slaney",
        mel_scale="slaney",
    )
    power = spectrogram(
        samples,
        window_function(FFT_SIZE, "hann", periodic=True),
        frame_length=FFT_SIZE,
        hop_length=HOP_SIZE,
        power=2.0,
        center=True,
        pad_mode="constant",
        mel_filters=filters,
        mel_floor=0.0,
    )
    mel = np.log10(1.0 + LOG_SCALE * power.T)[:FRAME_COUNT]
    padded = np.zeros((FRAME_COUNT, BAND_COUNT), np.float32)
    padded[: len(mel)] = mel
    return ((padded - NORMALISATION_MEAN) / (2 * NORMALISATION_DEVIATION)).astype(np.float32)


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} MODEL OUTDIR", file=sys.stderr)
        return 2
    output_directory = Path(sys.argv[2])
    output_directory.mkdir(parents=True, exist_ok=True)

    options = onnxruntime.SessionOptions()
    options.intra_op_num_threads = 1
    options.inter_op_num_threads = 1
    session = onnxruntime.InferenceSession(sys.argv[1], options, providers=["CPUExecutionProvider"])

    for name in SIGNAL_SECONDS:
        features = normalised_mel(signal(name))
        features[STORED_FRAMES].astype("<f4").tofile(output_directory / f"{name}_maest_mel_frames.f32")
        embedding = session.run(None, {"input_features": features[None, None]})[0][0]
        embedding.astype("<f4").tofile(output_directory / f"{name}_maest_emb_int8.f32")
    return 0


if __name__ == "__main__":
    sys.exit(main())
