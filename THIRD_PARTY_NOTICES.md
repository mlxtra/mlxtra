# Third-Party Notices

MLXtra is licensed under Apache-2.0. Runtime dependencies, model libraries,
models, and datasets are licensed separately by their respective owners.

This repository references or bundles tooling for:

- MLX and MLX-LM by Apple
- mlx-vlm by Prince Canuma and contributors
- mflux by Filip Strand and contributors
- Higgs Audio v3 TTS by Boson AI
- ACE-Step 1.5 by ACE-Step contributors
- Magenta RealTime 2 by Google LLC
- Hugging Face Hub tooling
- Swift Markdown by the Swift project
- Python and Python package dependencies used by the local runtime
- spaCy English `en_core_web_sm` language data by Explosion (MIT), used by Kokoro
- OpenSSL by the OpenSSL Project (Apache-2.0), linked into bundled Python
- liblzma from XZ Utils by the Tukaani Project (0BSD), linked into bundled Python

Source-built Python runtimes include Python, OpenSSL, and XZ license texts under
`python/Frameworks/Versions/3.12/Resources/licenses/`.

Bundled runtime packages and model artifacts remain under their own licenses
and notices. MLXtra does not relicense model weights, datasets, or third-party
runtime dependencies. Users and distributors are responsible for complying with
each upstream license and usage term.
