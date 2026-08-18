# Build the Watara Supervision port ROM (Phase 5).
# Requires cc65 (ca65/ld65) + python3/pypng. Graphics + levels are extracted from
# the user's own ROM at build time (rule 5): no ROM-derived bytes are committed.
# Output: build/super-mario-land.sv (gitignored).

AS      = ca65
LD      = ld65
ASFLAGS = --cpu 65C02 -g -I src
CFG     = cfg/supervision.cfg
ROM_IN  = super-mario-land-gb.gb
SVT     = build/gfx/w1_obj_8000.svt
W2GFX   = build/gfx/w2_ovl_8A00.svt build/gfx/w2_ovl_9310.svt
LVL     = build/levels/level_01.bin
ARC     = build/data/jumparc.bin
TABLES  = build/data/jumparc.bin build/data/speedtab.bin build/data/mario_poses.bin build/data/mario_big_poses.bin build/data/statusbar.bin
# leveldata.o LAST: the level header + blobs must sit at the tail of the LEVELS
# segment so every bank shares the same common prefix (see tools/pack_banks.py).
OBJS    = build/main.o build/gfxdata.o build/datatables.o build/leveldata.o
ROM     = build/super-mario-land.sv

all: $(ROM)

$(ROM): $(OBJS) $(CFG) tools/pack_banks.py tools/gen_w2abi.py src/w2code.s src/kit_mar23.inc src/w2stub.s cfg/w2code.cfg cfg/w2stub.cfg $(W2GFX)
	$(LD) -C $(CFG) $(OBJS) -o $@ -m build/rom.map -Ln build/rom.lbl --dbgfile build/rel.dbg
	python3 tools/gen_w2abi.py build/rel.dbg build/w2abi.inc
	$(AS) $(ASFLAGS) -I build src/w2code.s -o build/w2code.o
	$(LD) -C cfg/w2code.cfg build/w2code.o -o build/w2code.bin
	$(AS) $(ASFLAGS) -I build -D YUR22 src/w2code.s -o build/w2code22.o
	$(LD) -C cfg/w2code.cfg build/w2code22.o -o build/w2code22.bin
	$(AS) $(ASFLAGS) -I build -D MAR23 src/w2code.s -o build/w2code23.o
	$(LD) -C cfg/w2code.cfg build/w2code23.o -o build/w2code23.bin -m build/w2code23.map
	$(AS) $(ASFLAGS) -I build src/w2stub.s -o build/w2stub.o
	$(LD) -C cfg/w2stub.cfg build/w2stub.o -o build/w2stub.bin
	python3 tools/pack_banks.py $@ build/rom.map 0:1 2:2 3:3 4:4 5:5
	@cp build/rel.dbg build/dbg.txt   # the sim harness reads symbols from here:
	@echo "built $@ ($$(wc -c < $@) bytes)"   # no separate debug build anymore

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
