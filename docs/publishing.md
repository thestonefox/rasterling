# Publishing Rasterling

Rasterling is distributed on [Hex](https://hex.pm/packages/rasterling), with
[API documentation on HexDocs](https://rasterling.hexdocs.pm/). Source stays on
GitHub. Package releases and documentation updates use separate commands.

## Validate a package release

Choose an unpublished version in `mix.exs`. From the repository root, run:

```sh
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix test --warnings-as-errors
mix docs --warnings-as-errors
mix hex.build --output tmp/rasterling.tar
```

Create the ignored `tmp` directory first if it is absent. Review the package's
listed files and dependencies. Only `lib`, public documentation, project metadata
and the MIT license belong in it. Tests, fixtures, local build output, benchmarks,
Git data, credentials and local configuration are excluded by the explicit
package file list. ExDoc and its dependencies are development-only and excluded
from the package's dependency requirements. There are no runtime dependencies.

Review the generated documentation and let CI pass before publishing.

## Authenticate and publish

Use a confirmed [Hex account](https://hex.pm/signup) with ownership of Rasterling:

```sh
mix hex.user auth
mix hex.publish
```

Run authentication locally and keep credentials outside the repository. The
publish command builds the package and documentation and asks for confirmation.
Review the summary before accepting. GitHub trusted publishing can be configured
for later releases without storing a long-lived Hex API key in CI.

After publication, tag the exact released Git commit with its version and push
the commit and tag. Install the published version in a fresh application and run
`mix deps.get` and `mix compile`. Test a decode from the installed package.
Publishing Rasterling does not update consumers or their lockfiles automatically.

## Update documentation only

For a documentation correction to an existing release, keep its version in
`mix.exs`, validate with `mix docs --warnings-as-errors`, then run:

```sh
mix hex.publish docs
```

This updates HexDocs without replacing the package or publishing a new version.
Changes to files inside the downloadable package require a new package release.

Official reference: <https://hex.pm/docs/publish>.
