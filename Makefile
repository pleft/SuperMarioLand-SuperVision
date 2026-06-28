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
OBJS    = build/main.o build/gfxdata.o build/leveldata.o build/datatables.o
ROM     = build/super-mario-land.sv

all: $(ROM)

$(ROM): $(OBJS) $(CFG)
	$(LD) -C $(CFG) $(OBJS) -o $@
	@echo "built $@ ($$(wc -c < $@) bytes)"

build/main.o: src/main.s src/supervision.inc
	@mkdir -p build
	$(AS) $(ASFLAGS) src/main.s -o $@

build/gfxdata.o: src/gfxdata.s $(SVT)
	@mkdir -p build
	$(AS) $(ASFLAGS) src/gfxdata.s -o $@

build/leveldata.o: src/leveldata.s $(LVL)
	@mkdir -p build
	$(AS) $(ASFLAGS) src/leveldata.s -o $@

build/datatables.o: src/datatables.s $(ARC)
	@mkdir -p build
	$(AS) $(ASFLAGS) src/datatables.s -o $@

# Extract + convert assets from the user's ROM.
$(SVT): tools/extract_gfx.py $(ROM_IN)
	python3 tools/extract_gfx.py
$(LVL): tools/extract_levels.py $(ROM_IN)
	python3 tools/extract_levels.py
$(ARC): tools/extract_tables.py $(ROM_IN)
	python3 tools/extract_tables.py

clean:
	rm -f $(OBJS) $(ROM)

.PHONY: all clean
