; Game data tables (ROM-derived BUILD ARTIFACTS from tools/extract_tables.py; rule 5).
.segment "LEVELS"
.export jumparc
jumparc:
    .incbin "build/data/jumparc.bin"          ; 27 bytes; $7F = apex marker
.export speedtab
speedtab:
    .incbin "build/data/speedtab.bin"         ; 6 bytes: walk speed px/frame
