# SAPHIR DATA contract fixtures

`reference-v1` is a small, deterministic SAPHIR DATA folder used only by
automated tests. It deliberately contains the edge cases that have caused
compatibility regressions in the past:

- an employee with no entries;
- an employee with exactly one entry stored as a JSON array;
- an employee with several entries;
- an employee with an active entry (`punchOut: null`);
- a legacy one-entry file stored as a JSON object and without newer optional
  entry fields;
- one active project and one archived project.

The fixture contains no usable credentials. Tests must copy it to a unique
temporary directory before starting SAPHIR or performing any write. The files
under `reference-v1` are reference inputs and must remain byte-for-byte
unchanged during a test.
