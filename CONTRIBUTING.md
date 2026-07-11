# Adding a lab

Create each lab at `YYYY/MM/DD/{slug}/`. It must contain:

- `README.md`
- `metadata.json`
- `.gitignore`

Use this metadata shape:

```json
{
  "title": "Human-readable project title",
  "tags": ["tag-a", "tag-b"]
}
```

Keep source code and configuration in this repository. Put large or reusable
fixtures in [kiarina/test-assets](https://github.com/kiarina/test-assets), then
download the required release asset into the shared root-level `tests/assets/`
directory:

```sh
make download-test-assets
```

Update `RELEASE_VERSION` and `ASSETS_VERSION` at the top of `Makefile` when
changing the pinned asset release.

If the lab has a default task, place it below `.mise/tasks/`. From the repository
root, `make` discovers these labs and runs each one.

After adding or changing metadata, rebuild the top-level index:

```sh
make build-readme
```
