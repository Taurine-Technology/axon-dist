# axon-dist

Public PEP 503 "simple" index for Axon agent wheels, served via GitHub Pages at
<https://taurine-technology.github.io/axon-dist/simple/>. Source lives in
private repos (`axon-shared`, `axon-agent-ce`, `axon-agent-ee`); only release
artefacts land here. Every wheel published is immutable — `publish-wheel.py`
refuses to overwrite an existing version — so a given filename always refers
to the same bytes.

Devices install via:

```
pip install \
    --index-url https://taurine-technology.github.io/axon-dist/simple/ \
    --extra-index-url https://pypi.org/simple/ \
    axon-agent-ee==X.Y.Z
```

The `--extra-index-url` keeps transitive public deps (grpcio, protobuf,
nfstream, …) resolving from real PyPI — we do not mirror PyPI here.

## Publishing

Release workflows in each source repo build a wheel on `v*.*.*` tag push,
check out this repo with a PAT, run `publish-wheel.py`, commit, and push.
Pages redeploys on every push to `main`.

## Bandwidth note

GitHub Pages has a ~100 GB/month soft bandwidth limit. Wheel sizes are small
(sub-MB) so a few hundred devices pulling occasionally is well within budget;
high-frequency CI pulling wheels directly from here would not be. If we ever
approach the limit, the escape hatch is a release-assets-based index or a
CDN-backed mirror.
