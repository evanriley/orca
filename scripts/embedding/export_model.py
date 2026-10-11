"""Export the audio tower and projection of laion/clap-htsat-unfused to ONNX.

Usage: export_model.py OUTDIR

Writes OUTDIR/clap_audio_fp32.onnx and its dynamically quantised form
OUTDIR/clap_audio_int8.onnx, the file liborca pins by size and SHA-256, and
prints both files' size and SHA-256. The weights are read from safetensors
only. Set HF_HUB_OFFLINE=1 to use only the local Hugging Face cache.

The pinned file came from Python 3.14.7, torch 2.13.0, transformers 5.17.0,
onnx 1.23.2 and onnxruntime 1.27.1. Other versions may write different bytes.
"""

import hashlib
import sys
from pathlib import Path

import onnx
import torch
from huggingface_hub import hf_hub_download
from onnxruntime.quantization import QuantType, quantize_dynamic
from transformers import ClapModel

REPOSITORY = "laion/clap-htsat-unfused"
REVISION = "79b58ed25fc00386262a2bea4b19fd21dc4310a0"
OPSET_VERSION = 17
IR_VERSION = 9
FRAME_COUNT = 1001
BAND_COUNT = 64


class AudioEmbedding(torch.nn.Module):
    def __init__(self, clap: ClapModel) -> None:
        super().__init__()
        self.audio_model = clap.audio_model
        self.audio_projection = clap.audio_projection

    def forward(self, input_features: torch.Tensor) -> torch.Tensor:
        pooled = self.audio_model(input_features=input_features).pooler_output
        return self.audio_projection(pooled)


def snapshot_directory() -> Path:
    paths = [
        hf_hub_download(REPOSITORY, name, revision=REVISION)
        for name in ("config.json", "model.safetensors")
    ]
    return Path(paths[-1]).parent


def set_ir_version(path: Path) -> None:
    model = onnx.load(str(path))
    model.ir_version = IR_VERSION
    onnx.save(model, str(path), save_as_external_data=False)


def export(output_directory: Path) -> list[Path]:
    output_directory.mkdir(parents=True, exist_ok=True)
    clap = ClapModel.from_pretrained(
        snapshot_directory(), use_safetensors=True, trust_remote_code=False
    ).eval()
    network = AudioEmbedding(clap).eval()

    fp32 = output_directory / "clap_audio_fp32.onnx"
    torch.onnx.export(
        network,
        (torch.zeros(1, 1, FRAME_COUNT, BAND_COUNT),),
        str(fp32),
        input_names=["input_features"],
        output_names=["embedding"],
        opset_version=OPSET_VERSION,
        dynamo=False,
        do_constant_folding=True,
    )
    set_ir_version(fp32)

    int8 = output_directory / "clap_audio_int8.onnx"
    quantize_dynamic(str(fp32), str(int8), weight_type=QuantType.QUInt8)
    set_ir_version(int8)
    return [fp32, int8]


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} OUTDIR", file=sys.stderr)
        return 2
    for path in export(Path(sys.argv[1])):
        data = path.read_bytes()
        print(path.name, len(data), hashlib.sha256(data).hexdigest())
    return 0


if __name__ == "__main__":
    sys.exit(main())
