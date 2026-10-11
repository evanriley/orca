"""Write the reference data liborca's embedding tests compare against.

Usage: make_reference.py MODEL OUTDIR

MODEL is the clap_audio_int8.onnx that export_model.py writes. For each test
signal, OUTDIR receives NAME_mel_frames.f32, the reference feature
extractor's mel frames 0, 1, 2, 500, 998, 999 and 1000 as 7 x 64 little-endian
float32, and NAME_emb_int8.f32, the model's 512 output values for the whole
spectrogram. Set HF_HUB_OFFLINE=1 to use only the local Hugging Face cache.
"""

import sys
from pathlib import Path

import numpy as np
import onnxruntime
from huggingface_hub import hf_hub_download
from transformers import ClapFeatureExtractor

REPOSITORY = "laion/clap-htsat-unfused"
REVISION = "79b58ed25fc00386262a2bea4b19fd21dc4310a0"
SAMPLE_RATE = 48_000
STORED_FRAMES = [0, 1, 2, 500, 998, 999, 1000]
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
    extractor = ClapFeatureExtractor.from_pretrained(
        Path(hf_hub_download(REPOSITORY, "preprocessor_config.json", revision=REVISION)).parent
    )

    for name in SIGNAL_SECONDS:
        features = extractor([signal(name)], sampling_rate=SAMPLE_RATE, return_tensors="np")[
            "input_features"
        ].astype(np.float32)
        if features.shape != (1, 1, 1001, 64):
            print(
                f"{name}: features have shape {features.shape}; expected (1, 1, 1001, 64)",
                file=sys.stderr,
            )
            return 1
        features[0, 0][STORED_FRAMES].astype("<f4").tofile(
            output_directory / f"{name}_mel_frames.f32"
        )
        embedding = session.run(None, {"input_features": features})[0][0]
        embedding.astype("<f4").tofile(output_directory / f"{name}_emb_int8.f32")
    return 0


if __name__ == "__main__":
    sys.exit(main())
