# Sound similarity

Radio and Daily Mixes rank by how tracks sound when Orca has an
audio-embedding model. Without one they rank by tempo, key and energy instead,
and nothing else changes. Orca downloads a model only when asked to.

| Model | File | Size | Values per track | Licence of the weights |
| --- | --- | --- | --- | --- |
| Standard (default) | `clap_audio_int8.onnx` | 32.6 MB | 512 | Apache-2.0 |
| Large | `maest_audio_int8.onnx` | 80.4 MB | 768 | CC BY-NC-SA 4.0 |

Large tells genres and artists apart better than Standard and takes longer to
analyze. The Nix package includes Standard only. For any other build, or to use
Large, Settings › Listening › Sound Similarity in `orca-gtk` has a Model row
that picks Standard or Large; picking a model that is not installed offers
Download, which fetches it from `github.com` to
`$XDG_DATA_HOME/orca/models/`. `orca-cli` does the same, with `--model` naming
`clap_htsat_unfused` (the default) or `discogs_maest`. Either installs the file
only when its size and SHA-256 are the ones the build expects:

```sh
models="${XDG_DATA_HOME:-$HOME/.local/share}/orca/models"
orca-cli download-embedding-model "$models/clap_audio_int8.onnx"
orca-cli download-embedding-model "$models/maest_audio_int8.onnx" \
  --model discogs_maest
```

`curl` does the same without a build of Orca. Standard:

```sh
models="${XDG_DATA_HOME:-$HOME/.local/share}/orca/models"
mkdir -p "$models"
curl -L -o "$models/clap_audio_int8.onnx" \
  https://github.com/evanriley/orca/releases/download/model-clap-int8-1/clap_audio_int8.onnx
echo "12d3e2c1593ba111df6103feac2f3ce4f4e85e5efc2ad927ac16a8402e7b3c36  $models/clap_audio_int8.onnx" | sha256sum -c
```

Large:

```sh
models="${XDG_DATA_HOME:-$HOME/.local/share}/orca/models"
mkdir -p "$models"
curl -L -o "$models/maest_audio_int8.onnx" \
  https://github.com/evanriley/orca/releases/download/model-maest-int8-1/maest_audio_int8.onnx
echo "fcdf35e3b8737cb0853bb83cadd7a62885f70f1afe30cde3f185e61eb06d843e  $models/maest_audio_int8.onnx" | sha256sum -c
```

Orca recognises a model file by its size and SHA-256, so the file in use
decides the model. `ORCA_EMBEDDING_MODEL=PATH` names a file in `orca-gtk`
instead; `orca-cli` takes `--embedding-model PATH` or the same variable for
`analyze-library`, `similar`, `radio`, `home` and `mixes` (see
[the CLI reference](cli.md#environment-variables)). The Nix package keeps its
Standard file at `share/orca/models/clap_audio_int8.onnx`, where `orca-gtk`
finds it; its `orca-cli` is given the path like any other.

Each model's embeddings are stored separately. After a switch, analyzing the
Library once measures each track with the new model, and switching back needs
no analysis. Embeddings of different models are never compared. A build with
`-Dembeddings=false` uses neither model.

Standard is Orca's 8-bit export of the audio part of
[`laion/clap-htsat-unfused`](https://huggingface.co/laion/clap-htsat-unfused),
whose weights are published as Apache-2.0; `scripts/embedding/export_model.py`
writes it. Large is Orca's 8-bit export of
[`mtg-upf/discogs-maest-30s-pw-129e`](https://huggingface.co/mtg-upf/discogs-maest-30s-pw-129e)
by the Music Technology Group, Universitat Pompeu Fabra, licensed
[CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/)
(non-commercial, attribution, share-alike); `scripts/embedding/export_maest.py`
writes it. Large is only ever downloaded, never bundled.
