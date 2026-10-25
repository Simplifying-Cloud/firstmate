# Pin verification: skills/security-audit vs upstream cloudflare/security-audit-skill

Pinned commit claimed by skills/security-audit/PROVENANCE.md:
c1c8a8c1471069fb0e188eeaff69b8e8db6564a8 ("Clarify guidance and full audit modes")

Commands run (clone in /tmp, removed after verification):

    git ls-remote https://github.com/cloudflare/security-audit-skill
      -> c1c8a8c1471069fb0e188eeaff69b8e8db6564a8  HEAD   (commit exists upstream)

    git clone -q https://github.com/cloudflare/security-audit-skill /tmp/sas-verify
    git -C /tmp/sas-verify checkout -q c1c8a8c1471069fb0e188eeaff69b8e8db6564a8
    # file lists of upstream skills/security-audit vs vendored skills/security-audit
    diff /tmp/up.files /tmp/vend.files
      -> only additions on the vendored side: ./LICENSE and ./PROVENANCE.md
         (both named by the provenance note: LICENSE "vendored unchanged beside this note", PROVENANCE is the note itself)

    # per-file byte comparison of every upstream file
    cmp each upstream skills/security-audit/<file> against vendored counterpart
      -> all upstream files byte-identical

    cmp /tmp/sas-verify/LICENSE skills/security-audit/LICENSE
      -> byte-identical (upstream repo-root LICENSE, MIT, Cloudflare)

Result: the vendored copy is a complete, byte-for-byte match of the pinned
upstream commit's skills/security-audit directory, plus exactly the two files
the provenance note declares adding.
