# Location of plenary.nvim, which provides the busted test runner. Override when it lives elsewhere:
#   make test PLENARY_DIR=/path/to/plenary.nvim
PLENARY_DIR ?= $(HOME)/.local/share/nvim/lazy/plenary.nvim

# Run everything below tests/specs, or a single spec file or directory:
#   make test TEST_FILES=tests/specs/sven/lib/svn/status_spec.lua
TEST_FILES ?= tests/specs

test:
	PLENARY_DIR=$(PLENARY_DIR) TEST_FILES=$(TEST_FILES) NVIM_APPNAME=sven-test nvim --headless -S "./tests/init.lua"

lint:
	stylua --check .

format:
	stylua .

.PHONY: test lint format
