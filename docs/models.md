# Models

Bundled manifest: `App/Resources/ModelCatalog.json` (validated by `scripts/verify-manifest.sh` and a unit test).

| Catalog ID | Artifact | Immutable revision | Files | Total | License |
|---|---|---|---|---|---|
| parakeet-en-v2 | mlx-community/parakeet-tdt-0.6b-v2 (upstream nvidia/parakeet-tdt-0.6b-v2) | 8ae155301e23d820d82aa60d24817c900e69e487 | 5 | 2.47 GB | CC-BY-4.0 |
| qwen3-4b-instruct-2507-4bit | mlx-community/Qwen3-4B-Instruct-2507-4bit (upstream Qwen/Qwen3-4B-Instruct-2507) | 50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b | 11 | 2.28 GB | Apache-2.0 |

Every file's byte count and SHA-256 were computed from a download at the pinned revision on 5 Nov 2026; LFS
digests match Hugging Face's published `lfs.sha256`.

Loading: Parakeet via `ParakeetModel.fromDirectory` and `generate(audio: MLXArray)` from in-memory PCM;
Qwen via `LLMModelFactory.loadContainer(from: directory, using: LocalTokenizerLoader)` (swift-transformers
`AutoTokenizer.from(modelFolder:)`) and the model's own `chat_template.jinja`. Neither path uses a hub client.

Download path (`ModelManager`): explicit user action → staging folder → ≤2 concurrent HTTPS requests with
Range/If-Range resume → redirect host allow-list (huggingface.co, hf.co, *.xethub.hf.co, *.cloudfront.net) → exact
size + SHA-256 → no symlinks/unexpected files → atomic rename into `Models/<id>/<revision>/` with `.verified.json`.
Installed state is determined by the verified marker, never by file existence.
