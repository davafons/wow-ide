# Open-source and Third-party Reuse Policy

## Project license

WoW IDE is distributed under the MIT License. See the root `LICENSE` file.

## Donor project policy

- A public repository is not automatically reusable. Verify a license file and its scope before copying code.
- Prefer MIT, ISC, BSD-2-Clause, BSD-3-Clause, or Apache-2.0 for code donors, subject to a file-level audit and all notices/attributions.
- List donor project, upstream URL, license, version/commit, copied files, local modifications, and required notices in `THIRD_PARTY_NOTICES.md`.
- Keep adapted components narrow and isolate them behind project-owned interfaces to simplify updates or replacement.
- Re-check transitive dependency licenses before shipping a distributable app.
- Do not copy screenshots, logos, names, art, UI assets, or product text without rights. Product behavior can be studied and independently implemented.
- Projects under Elastic License, source-available non-OSI terms, or unclear/missing licenses are reference-only unless a deliberate legal decision authorizes reuse.

## Current candidates

| Project | Current treatment | Reason |
|---|---|---|
| Peekaboo | Candidate code/architecture donor; MIT is linked from its repository. Verify exact license text, commit, and source files before import. | Mac-specific, transparent browser overlay with click-through and hotkey behavior. |
| Astrum | Product/UX reference only. | WoW Mac overlay focus is relevant; reviewed product page does not establish source availability/license. |
| Interceptor | Technical reference only unless license choice is reviewed and explicitly accepted. | Repository states Elastic License 2.0. |
| Hudkit | Platform behavior reference only. | ISC but project lists macOS as unsupported. |

## Attribution

Preserve upstream copyright and license notices in copied source. Add a short source attribution in the relevant module documentation and the distributed notices file. Document substantial changes where the source license requires it.
