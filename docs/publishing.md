# Publishing Rasterling

Version 0.1.0 is prepared for its first public Hex release. This guide does not
mean it has already been published. Publishing keeps the source on GitHub and
adds a versioned package on Hex plus API documentation on HexDocs.

## Validate the release

From the repository root, with a clean working tree and the intended version in
`mix.exs`:

```sh
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix test --warnings-as-errors
mix docs --warnings-as-errors
mix hex.build --output tmp/rasterling-0.1.0.tar
```

Create the ignored `tmp` directory first if it is absent. Review the package's
listed files and dependencies. Only `lib`, public documentation, project metadata
and the MIT license belong in it. Tests, fixtures, local build output, benchmarks,
Git data, credentials and local configuration are excluded by the explicit
package file list. ExDoc and its dependencies are development-only and excluded
from the package's dependency requirements. There are no runtime dependencies.

Check package-name availability on Hex; a missing package does not reserve its
name. Review the generated documentation and let CI pass before publishing.

## Authenticate and publish

Create an account at <https://hex.pm/signup> and confirm its email, then run:

```sh
mix hex.user auth
mix hex.publish
```

Run authentication locally and keep credentials outside the repository. The
publish command builds the package and documentation and asks for confirmation.
Review the summary before accepting. No publishing credentials belong in CI for
this first release. Hex trusted publishing can be configured later; it cannot
create a package's first release.

After publication, tag the exact released Git commit as `v0.1.0` and push the
commit and tag. Install `{:rasterling, "~> 0.1.0"}` in a fresh application and run
`mix deps.get` and `mix compile`. Test a decode from the installed package.

Only then change Breeze Images from its pinned Git dependency to the Hex
requirement and refresh its lockfile. Publishing Rasterling does not update its
consumers automatically.

Official reference: <https://hex.pm/docs/publish>.
