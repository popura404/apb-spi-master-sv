PYTHON ?= python3
SEED ?= 1
FIFO_DEPTH ?= 16
NUM_CS ?= 4
PART ?= xc7z020clg400-1
PARAMS = --fifo-depth $(FIFO_DEPTH) --num-cs $(NUM_CS)

.PHONY: all sim test waves synth impl project xsim clean help

all: sim

sim:
	$(PYTHON) scripts/run.py sim $(PARAMS) --seed $(SEED)

test:
	$(PYTHON) scripts/run.py test --seed $(SEED)

waves:
	$(PYTHON) scripts/run.py sim $(PARAMS) --seed $(SEED) --waves

synth:
	$(PYTHON) scripts/run.py synth $(PARAMS) --part $(PART)

impl:
	$(PYTHON) scripts/run.py synth $(PARAMS) --part $(PART) --implement

project:
	$(PYTHON) scripts/run.py project $(PARAMS) --part $(PART)

xsim:
	$(PYTHON) scripts/run.py xsim --seed $(SEED)

clean:
	$(PYTHON) scripts/run.py clean

help:
	$(PYTHON) scripts/run.py --help
