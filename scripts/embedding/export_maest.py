"""Export the MAEST audio encoder of mtg-upf/discogs-maest-30s-pw-129e to ONNX.

Usage: export_maest.py OUTDIR

Writes OUTDIR/maest_audio_fp32.onnx and its dynamically quantised form
OUTDIR/maest_audio_int8.onnx, the file liborca pins by size and SHA-256, and
prints both files' size and SHA-256. The weights are read from safetensors
only and the network is built from transformers' own AST classes. Set
HF_HUB_OFFLINE=1 to use only the local Hugging Face cache.

The 30-second weights run on 10-second windows. The graph takes the normalised
log-mel spectrogram input_features of shape (1, 1, 626, 96) and returns
embedding of shape (1, 768): the mean of the class and distillation tokens
after transformer block 11, before the final layer norm. The position
embeddings keep the leading 62 of the 187 time columns, and the other columns
are not stored in the file.

The model is licensed CC BY-NC-SA 4.0 by the Music Technology Group,
Universitat Pompeu Fabra.

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
from transformers import ASTModel

REPOSITORY = "mtg-upf/discogs-maest-30s-pw-129e"
REVISION = "e5d670316c61b18aaef46ce66242fcd73870d792"
OPSET_VERSION = 17
IR_VERSION = 9
FRAME_COUNT = 626
BAND_COUNT = 96
LAYER_COUNT = 11
SPECIAL_TOKEN_COUNT = 2


class AudioEmbedding(torch.nn.Module):
    def __init__(self, encoder: ASTModel) -> None:
        super().__init__()
        embeddings = encoder.embeddings
        frequency_count, trained_time_count = embeddings.get_shape(encoder.config)
        patch_count = embeddings.patch_embeddings(
            torch.zeros(1, FRAME_COUNT, BAND_COUNT)
        ).shape[1]
        time_count = patch_count // frequency_count
        positions = embeddings.position_embeddings.detach()
        grid = positions[:, SPECIAL_TOKEN_COUNT:].reshape(
            1, frequency_count, trained_time_count, -1
        )[:, :, :time_count]
        self.patch_embeddings = embeddings.patch_embeddings
        self.register_buffer("patch_positions", grid.reshape(1, patch_count, -1))
        self.register_buffer(
            "special_tokens",
            torch.cat(
                (
                    embeddings.cls_token.detach() + positions[:, 0:1],
                    embeddings.distillation_token.detach() + positions[:, 1:2],
                ),
                dim=1,
            ),
        )
        self.layers = encoder.layers[:LAYER_COUNT]

    def forward(self, input_features: torch.Tensor) -> torch.Tensor:
        patches = self.patch_embeddings(input_features.squeeze(1)) + self.patch_positions
        state = torch.cat((self.special_tokens, patches), dim=1)
        for layer in self.layers:
            state = layer(state, None)
        return state[:, :SPECIAL_TOKEN_COUNT].mean(dim=1)


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


def load_encoder() -> ASTModel:
    encoder, loading = ASTModel.from_pretrained(
        snapshot_directory(),
        use_safetensors=True,
        trust_remote_code=False,
        output_loading_info=True,
    )
    if loading["missing_keys"]:
        raise SystemExit(
            f"{REPOSITORY}: weights missing for {sorted(loading['missing_keys'])}; "
            "expected a full encoder. Check the pinned revision."
        )
    return encoder.eval()


def export(output_directory: Path) -> list[Path]:
    output_directory.mkdir(parents=True, exist_ok=True)
    torch.set_num_threads(1)
    network = AudioEmbedding(load_encoder()).eval()

    fp32 = output_directory / "maest_audio_fp32.onnx"
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

    int8 = output_directory / "maest_audio_int8.onnx"
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
