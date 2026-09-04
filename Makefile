# Build the Watara Supervision port ROM (Phase 5).
# Requires cc65 (ca65/ld65) + python3/pypng. Graphics + levels are extracted from
# the user's own ROM at build time (rule 5): no ROM-derived bytes are committed.
# Output: build/super-mario-land.sv (gitignored).

AS      = ca65
LD      = ld65
ASFLAGS = --cpu 65C02 -g -I src
# make GODMODE=1  -> a TEST build whose hurt_mario returns immediately, so a run
# can traverse a whole level instead of dying in the first 10%. Pair it with the
# GB's own invincibility build so both sides are patched identically; never ask
# either about deaths (see docs/38 and the iddqd-rom-trap memory).
ifdef GODMODE
ASFLAGS += -D GODMODE
endif
CFG     = cfg/supervision.cfg
ROM_IN  = super-mario-land-gb.gb
SVT     = build/gfx/w1_obj_8000.svt
W2GFX   = build/gfx/w2_ovl_8A00.svt build/gfx/w2_ovl_9310.svt build/gfx/creature23.svt build/gfx/dshot23.svt
LVL     = build/levels/level_01.bin
ARC     = build/data/jumparc.bin
TABLES  = build/data/jumparc.bin build/data/speedtab.bin build/data/mario_poses.bin build/data/mario_big_poses.bin build/data/statusbar.bin
# leveldata.o LAST: the level header + blobs must sit at the tail of the LEVELS
# segment so every bank shares the same common prefix (see tools/pack_banks.py).
# GODMODE changes ASFLAGS, which the .o rules cannot see. Sharing artifacts
# between the two settings meant an incremental build could relink STALE objects
# and silently ship a ROM identical to the other flavour -- it did, twice, and a
# whole play session was spent wondering why invincibility did nothing. So the
# two settings share NOTHING: their own object dir, their own ROM name. Both
# stay incremental and neither can ever be the other.
OBJDIR  = build$(if $(GODMODE),/god)
OBJS    = $(OBJDIR)/main.o $(OBJDIR)/gfxdata.o $(OBJDIR)/datatables.o $(OBJDIR)/leveldata.o
ROM     = build/super-mario-land$(if $(GODMODE),-god).sv

all: $(ROM)

.PHONY: godmode
godmode:                         # the TEST ROM -> build/super-mario-land-god.sv
	$(MAKE) GODMODE=1

$(ROM): $(OBJS) $(CFG) tools/pack_banks.py tools/gen_w2abi.py src/w2code.s src/kit_mar23.inc src/kit_w3.inc $(wildcard src/kit_sh*.inc) src/w2stub.s src/w3stub.s tools/gen_w3data.py src/w3aux.s cfg/w3aux.cfg tools/make_512k.py cfg/w2code.cfg cfg/w2stub.cfg cfg/w3stub.cfg cfg/w3code.cfg cfg/w4code.cfg cfg/w43code.cfg src/kit_sky43.inc $(W2GFX) build/gfx/w3_ovl_9310.svt
	$(LD) -C $(CFG) $(OBJS) -o $@ -m build/rom.map -Ln build/rom.lbl --dbgfile build/rel.dbg
	python3 tools/gen_w2abi.py build/rel.dbg build/w2abi.inc
	$(AS) $(ASFLAGS) -I build src/w3aux.s -o build/w3aux.o
	$(LD) -C cfg/w3aux.cfg build/w3aux.o -o build/w3aux.bin -Ln build/w3aux.lbl
	python3 tools/gen_w3auxabi.py
	$(AS) $(ASFLAGS) -I build src/w2code.s -o build/w2code.o
	$(LD) -C cfg/w2code.cfg build/w2code.o -o build/w2code.bin
	$(AS) $(ASFLAGS) -I build -D YUR22 src/w2code.s -o build/w2code22.o
	$(LD) -C cfg/w2code.cfg build/w2code22.o -o build/w2code22.bin
	$(AS) $(ASFLAGS) -I build -D MAR23 src/w2code.s -o build/w2code23.o
	$(LD) -C cfg/w2code.cfg build/w2code23.o -o build/w2code23.bin -m build/w2code23.map -Ln build/w2code23.lbl
	$(AS) $(ASFLAGS) -I build src/w2stub.s -o build/w2stub.o
	$(LD) -C cfg/w2stub.cfg build/w2stub.o -o build/w2stub.bin
	python3 tools/gen_w3data.py super-mario-land-gb.gb 3
	$(AS) $(ASFLAGS) -I build -D EAS3 src/w2code.s -o build/w3code.o
	$(LD) -C cfg/w3code.cfg build/w3code.o -o build/w3code.bin -m build/w3code.map -Ln build/w3code.lbl
	python3 tools/gen_w3data.py super-mario-land-gb.gb 4
	$(AS) $(ASFLAGS) -I build -D EAS3 -D W4KIT src/w2code.s -o build/w4code.o
	$(LD) -C cfg/w4code.cfg build/w4code.o -o build/w4code.bin -m build/w4code.map -Ln build/w4code.lbl
	$(AS) $(ASFLAGS) -I build -D EAS3 -D W4KIT -D SKY43 src/w2code.s -o build/w43code.o
	$(LD) -C cfg/w43code.cfg build/w43code.o -o build/w43code.bin -m build/w43code.map -Ln build/w43code.lbl
	$(AS) $(ASFLAGS) -I build src/w3stub.s -o build/w3stub.o
	$(LD) -C cfg/w3stub.cfg build/w3stub.o -o build/w3stub.bin
	$(AS) $(ASFLAGS) -I build -D W4KIT src/w3stub.s -o build/w4stub.o
	$(LD) -C cfg/w3stub.cfg build/w4stub.o -o build/w4stub.bin
	$(AS) $(ASFLAGS) -I build -D W4KIT -D SKY43 src/w3stub.s -o build/w43stub.o
	$(LD) -C cfg/w3stub.cfg build/w43stub.o -o build/w43stub.bin
	python3 tools/pack_banks.py $@ build/rom.map 0:7 2:2 3:3 4:4 5:5 6:1 7:1 8:1
	python3 tools/make_512k.py $@ $@   # 512K default
	python3 tools/pack_w4.py $@        # World 4 -> pages 9 (resident) + 10 (cold),
	                                   # AFTER the 512K expansion creates them (docs/42; SuperPico set aside per user)
	@cp build/rel.dbg build/dbg.txt   # the sim harness reads symbols from here:
	@echo "built $@ ($$(wc -c < $@) bytes)"   # no separate debug build anymore

# w3_ballt is no longer assembled into main.o: each world's rows are a .bin
# (build/w{3,4}ball.bin, emitted by the gen runs inside the ROM recipe) pasted
# at the $B520 pin of its own resident bank by pack_banks/pack_w4.

$(OBJDIR)/main.o: src/main.s src/supervision.inc build/levels/title_map.bin build/gfx/title_tiles.svt build/audio/sfx.bin build/audio/sfx.inc build/audio/music.bin build/audio/music.inc
	@mkdir -p $(OBJDIR)
	$(AS) $(ASFLAGS) src/main.s -o $@

$(OBJDIR)/gfxdata.o: src/gfxdata.s $(SVT)
	@mkdir -p $(OBJDIR)
	$(AS) $(ASFLAGS) src/gfxdata.s -o $@

$(OBJDIR)/leveldata.o: src/leveldata.s $(LVL) build/levels/level_01_dedup.inc
	@mkdir -p $(OBJDIR)
	$(AS) $(ASFLAGS) -I build src/leveldata.s -o $@

build/levels/level_01_dedup.inc: build/levels/level_01.bin tools/gen_dedup_inc.py
	python3 tools/gen_dedup_inc.py build/levels/level_01.bin $@

$(OBJDIR)/datatables.o: src/datatables.s $(TABLES)
	@mkdir -p $(OBJDIR)
	$(AS) $(ASFLAGS) src/datatables.s -o $@

# Extract + convert assets from the user's ROM.
$(SVT) $(W2GFX): tools/extract_gfx.py $(ROM_IN)
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
	rm -f $(OBJS) $(ROM) build/god/*.o build/super-mario-land-god.sv

.PHONY: all clean

# a failed pack step (pack_w4 after make_512k) must not leave a fresh-looking,
# half-built image behind -- make would then report "Nothing to be done"
.DELETE_ON_ERROR:
