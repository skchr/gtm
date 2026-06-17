# gtm


## Build & Test

```bash
nim e build.nims          # build both (release + man page)
nim e build.nims -t       # TUI only
nim e build.nims -d       # daemon only
nim check src/gtm.nim     # TUI syntax check
nim check src/gtmd.nim    # daemon syntax check
# Tests:
nim r --path:src tests/test_ipc.nim
nim r --path:src tests/test_parse.nim
