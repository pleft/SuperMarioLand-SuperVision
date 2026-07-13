# Build the Watara Supervision port ROM (Phase 5).
# Requires cc65 (ca65/ld65) + python3/pypng. Graphics + levels are extracted from
# the user's own ROM at build time (rule 5): no ROM-derived bytes are committed.
# Output: build/super-mario-land.sv (gitignored).

AS      = ca65
LD      = ld65
ASFLAGS = --cpu 65C02 -I src
CFG     = cfg/supervision.cfg
ROM_IN  = super-mario-land-gb.gb
SVT     = build/gfx/w1_obj_8000.svt
LVL     = build/levels/level_00.bin
ARC     = build/data/jumparc.bin
TABLES  = build/data/jumparc.bin build/data/speedtab.bin build/data/mario_poses.bin build/data/mario_big_poses.bin build/data/statusbar.bin
# leveldata.o LAST: the level header + blobs must sit at the tail of the LEVELS
# segment so every bank shares the same common prefix (see tools/pack_banks.py).
OBJS    = build/main.o build/gfxdata.o build/datatables.o build/leveldata.o
ROM     = build/super-mario-land.sv

all: $(ROM)

$(ROM): $(OBJS) $(CFG) tools/pack_banks.py
	$(LD) -C $(CFG) $(OBJS) -o $@ -m build/rom.map
	python3 tools/pack_banks.py $@ build/rom.map 1:1 2:2
	@echo "built $@ ($$(wc -c < $@) bytes)"

build/main.o: src/main.s src/supervision.inc build/levels/title_map.bin build/gfx/title_tiles.svt build/audio/sfx.bin build/audio/sfx.inc build/audio/music.bin build/audio/music.inc
	@mkdir -p build
	$(AS) $(ASFLAGS) src/main.s -o $@

build/gfxdata.o: src/gfxdata.s $(SVT)
	@mkdir -p build
	$(AS) $(ASFLAGS) src/gfxdata.s -o $@

build/leveldata.o: src/leveldata.s $(LVL)
	@mkdir -p build
	$(AS) $(ASFLAGS) src/leveldata.s -o $@

build/datatables.o: src/datatables.s $(TABLES)
	@mkdir -p build
	$(AS) $(ASFLAGS) src/datatables.s -o $@

# Extract + convert assets from the user's ROM.
$(SVT): tools/extract_gfx.py $(ROM_IN)
	python3 tools/extract_gfx.py
$(LVL): tools/extract_levels.py $(ROM_IN)
	python3 tools/extract_levels.py
$(TABLES): tools/extract_tables.py $(ROM_IN)
	python3 tools/extract_tables.py
build/levels/title_map.bin build/gfx/title_tiles.svt: tools/extract_title.py $(ROM_IN)
	python3 tools/extract_title.py
build/audio/sfx.bin build/audio/sfx.inc: tools/extract_sfx.py $(ROM_IN)
	python3 tools/extract_sfx.py
build/audio/music.bin build/audio/music.inc: tools/extract_music.py $(ROM_IN)
	python3 tools/extract_music.py

clean:
	rm -f $(OBJS) $(ROM)

.PHONY: all clean
