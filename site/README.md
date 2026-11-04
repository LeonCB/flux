# Flux website

Static landing page for https://luma.ksmvc.ch. No npm dependencies or build step.
The canvas is an illustrative palette study, not the Rust simulation.

## Publish with GitHub Pages

1. In repository Settings > Pages, select **GitHub Actions** as the source.
2. Set **Custom domain** to `luma.ksmvc.ch` and save.
3. At the DNS provider create a CNAME record: `flux` -> `ken5998.github.io`.
4. Once GitHub's DNS check and certificate provisioning complete, enable **Enforce HTTPS**.
5. Publish the stable release before deploying its version text, then push to
   main or run the workflow manually. The workflow builds and tests the Windows
   ZIP before publishing the site. Both download buttons open the GitHub
   `releases/latest` page, where users choose MSI or ZIP and read release notes.
   The page also includes the known MSI uninstall rollback limitation.
   Documentation-only changes never replace a released download.

The site offers MSI or ZIP through the GitHub release page, with no direct asset
download links. The old Inno EXE is withdrawn. Keep the version text and known
issue note aligned with the current stable release. GitHub releases/latest must
resolve a published stable release before the site is deployed.

The CNAME file documents the intended domain, but custom workflows still require
setting the domain in GitHub Pages settings. Do not point the DNS CNAME at a URL
or at `ken5998.github.io/flux`.

Documentation: https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/managing-a-custom-domain-for-your-github-pages-site

Google Fonts supplies the typefaces; system fonts are used if unavailable.
The page respects reduced-motion preferences and pauses its canvas when hidden.
