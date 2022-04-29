# Ziggy Image library

This is a work in progress library to create, process, read and write different image formats with [Zig](https://ziglang.org/) programming language with focus on performance and minimizing memory allocations.

![License](https://img.shields.io/github/license/igor84/ziggyimg) ![Issue](https://img.shields.io/github/issues-raw/igor84/ziggyimg?style=flat) ![Commit](https://img.shields.io/github/last-commit/igor84/ziggyimg) ![CI](https://github.com/igor84/ziggyimg/workflows/CI/badge.svg)

## Install & Build

This project assume current Zig master (0.10.0+).

How to add to your project:
1. Clone this repository or add as a submodule
1. Add to your `build.zig`
```
exe.addPackagePath("ziggyimg", "ziggyimg/ziggyimg.zig");
```

To run the test suite run
```
zig build test
```

## TODO
- [ ] Add Png Test suite
- [ ] Review usage of var vs const
- [ ] Implement RGB deinterlacing
- [ ] Implement RGB processor that converts palette to rgb
- [ ] Execute performance tests
- [ ] Add named colors
- [ ] Provide fast way for most often needed sRGB to Linear and Linear to sRGB conversion