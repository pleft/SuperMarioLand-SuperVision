; Game data tables (ROM-derived BUILD ARTIFACTS from tools/extract_tables.py; rule 5).
.segment "LEVELS"
.export jumparc
jumparc:
    .incbin "build/data/jumparc.bin"          ; 27 bytes; $7F = apex marker
.export speedtab
speedtab:
    .incbin "build/data/speedtab.bin"         ; 6 bytes: walk speed px/frame
.export mario_poses
mario_poses:
    .incbin "build/data/mario_poses.bin"      ; 4 poses x 4 tiles (stand,walkA,walkB,jump)
.export statusbar_tiles
statusbar_tiles:
    .incbin "build/data/statusbar.bin"        ; 2x20 status-bar template (BG map $9800)
