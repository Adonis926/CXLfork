# CXL-DE OpenWhisk E2E integration

This branch freezes the OpenWhisk experiment controller used for the Cohort
Figure 9 CXL-DE result.  Its workload definition and VM memory layout are
unchanged from commit `0acfe0d239109236c25d303382ca155f2ce8b738`.

The runner now accepts runtime resources through the `OWE_*` variables in
`config/openwhisk-state-action-eval-103.env`.  In particular,
`OWE_BACKEND_HELPER` resolves either a real-CXL devdax device or the reserved
DRAM devdax device.  Both backends keep the evaluated device-relative layout:

- CXLfork state: `[4,8) GiB`
- HydraRPC shared memory: `[8,12) GiB`

Use the top-level CXL-DE repository scripts for checkout, asset linking,
preflight, provisioning, and execution.  Runtime images, JDK, `wsk`, the
standalone OpenWhisk JAR, keys, and results are intentionally not stored in
Git.
