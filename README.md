## How to Run

1. Install the headers. (Run Once)

```bash
bash ./vendor/cpython/install.sh
```

2. Run the program.

```bash
zig build run
```

> [!WARNING]
> Make sure you have Zig 0.15.1 installed.

## How to reproduce

1. Install the backend. (Run Once)

```bash
zig build run -- use cpu
```

2. Trigger the segment fault.

```bash
zig build run -- marker init test
```
