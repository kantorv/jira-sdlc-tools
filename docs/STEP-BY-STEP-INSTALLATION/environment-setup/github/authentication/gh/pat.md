---
slug: /step-by-step-installation/pat
sidebar_position: 1
sidebar_label: PAT
---

# PAT

Create a **granular GitHub PAT** with:

- `Contents` — read/write
- `Pull requests` — read/write

GitHub may also show `Metadata` / `Meta` as a read permission; it is added
automatically.

If the project's repos are git submodules of this one, give the token those
**member repos** too, with the same two permissions: member PRs are opened with
it ([Submodules → Setup](../../../../../submodules/setup.md)).

See [Creating a GitHub PAT](../../../../../process/SECURITY.md#github) and
[GH-PAT-SESSION-LOGIN.md](../../../../../github/GH-PAT-SESSION-LOGIN.md).

It's never a `gh` login: every `gh` call the skills make carries this PAT for
that one command — see
[Verify GitHub authentication](../../verify-github-authentication.md).
