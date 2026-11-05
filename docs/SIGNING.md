# Signing the Windows build with SignPath

Windows release builds (`iptv_player.exe` and `IPTV-Player-windows-setup.exe`) can be signed for
free through the [SignPath Foundation](https://signpath.org) open-source program. Signing makes
Windows show a verified publisher instead of "Unknown publisher". SmartScreen warnings fade as
signed downloads build up reputation.

The build workflow is already set up for this. Until the steps below are done, releases are
built **unsigned** exactly as before; nothing breaks.

## 1. Apply

1. Go to <https://signpath.org/apply> and apply with this repository
   (`https://github.com/pyroRocket/IPTV-Player`). It qualifies on licence (MIT) and being public.
2. Approval is manual and can take a while. SignPath may ask questions about the project.
3. They check that the README has a code signing policy. It's already in the README under
   **Code signing policy**. Edit the names there if anyone else helps maintain the project.

## 2. Set up the project in SignPath

When you're accepted, SignPath creates an organization for you. In the SignPath web app:

1. **Project:** create (or check) a project with the slug `iptv-player`.
2. **Trusted build system:** connect it to GitHub Actions for this repository, following
   SignPath's prompts.
3. **Artifact configurations:** create two, with these slugs, and paste in the XML from this repo:
   - `app`: [`.signpath/artifact-configurations/app.xml`](../.signpath/artifact-configurations/app.xml)
   - `installer`: [`.signpath/artifact-configurations/installer.xml`](../.signpath/artifact-configurations/installer.xml)
4. **Signing policy:** use the release policy, slug `release-signing` (or tell me the slug they
   gave you). Add yourself as an **approver**.
5. **API token:** create one for a CI user with permission to submit signing requests.

## 3. Add the settings to GitHub

In the repository: **Settings → Secrets and variables → Actions**

- **Secrets** tab, **New repository secret**:
  - `SIGNPATH_API_TOKEN`: the API token from step 2.5
- **Variables** tab, **New repository variable**:
  - `SIGNPATH_ORGANIZATION_ID`: your organization ID, shown in the SignPath web app
  - only if your slugs differ from the defaults: `SIGNPATH_PROJECT_SLUG`, `SIGNPATH_SIGNING_POLICY_SLUG`

## 4. Releasing

Publish a release as usual (Releases → Draft a new release → tag `vX.Y.Z`). While it builds:

1. The Windows job sends `iptv_player.exe` to SignPath and waits.
2. **Approve the request in SignPath** (you get an email). The job continues once it's signed.
3. It builds the installer from the signed app, then sends the installer for signing. **Approve
   that request too.**
4. The signed `IPTV-Player-windows-setup.exe` and `IPTV-Player-windows.zip` are attached to the
   release.

Each request waits up to an hour for approval. If it times out, re-run the Windows job from the
Actions tab.

Regular pushes and pull requests are never sent for signing, so there is nothing to approve
day to day.
