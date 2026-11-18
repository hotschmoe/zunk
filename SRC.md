# Source notes

## src/bind/bind.zig

The exchange buffer is shared with JavaScript and reused for successive strings;
callers must copy data they need to retain. Callback ID zero denotes failure or
no callback, and registered IDs are not reused.
