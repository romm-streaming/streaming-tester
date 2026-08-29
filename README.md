# RomM streaming tester

> **⚠️ This is a testing aid, not a product.**
>
> It exists so people can try RomM's new **emulator streaming** feature before it
> ships and report back. It is **not actively maintained**, it **will not work on
> every setup**, and it comes with no support. It targets one shape of machine:
> a normal **Linux server** with **Docker + Docker Compose v2** and a
> **supported GPU** (Intel, AMD, or NVIDIA). Unraid, TrueNAS, Podman, Docker
> Desktop, macOS, Windows/WSL, rootless Docker and the like are untested and
> probably broken.

## What it does

The installer builds a **fully isolated** RomM stack in the folder you run it
from. It never touches an existing RomM install:

- All containers, the compose project and the network are prefixed
  `streaming-test-` so nothing collides with your real RomM.
- Database, metadata, config, saves, certificates and the webstation home all
  live inside the install folder.
- Your ROM library is the **only** thing mounted from outside, and it is
  mounted **read-only**.
- It is served over https on its own port (default `8443`).
- Streaming is enabled for **every** platform the webstation container can
  serve, so you can test whatever you own.

Everything is removable with one command.

## Requirements

- Linux, `bash`, `curl`
- Docker Engine and Docker Compose v2 (`docker compose`)
- A GPU with its driver loaded:
  - **Intel / AMD**: `/dev/dri` must exist.
  - **NVIDIA**: proprietary driver and the
    [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
    with the `nvidia` runtime registered in Docker. We recommend **current
    binary drivers, 595 or newer**; older drivers may not encode correctly.
- Disk space for the images (the webstation image is large).

## Run it

```bash
mkdir romm-streaming && cd romm-streaming
curl -fsSL https://raw.githubusercontent.com/romm-streaming/streaming-tester/main/streaming-tester.sh | bash
```

The wizard will:

1. Check for Docker/Compose and whether `sudo` is needed to use them.
2. Detect your GPU. If none is found it stops; if several are found it asks
   which one to use.
3. Ask for your ROM library folder — the one that has the platform folders
   directly inside it (e.g. the folder containing `nes/`, `snes/`, `ps2/`).
4. Ask for a port (default `8443`).
5. Generate secrets, a self-signed certificate, the RomM config and the compose
   file, then pull the images and start the stack.

When it finishes it prints the URL. Your browser will warn about the
self-signed certificate once; accept it. Create the admin user in the setup
wizard, scan the library, and open a game on a streaming-enabled platform.

## Managing the stack

Run these from the install folder (prefix with `sudo` if the installer told you
Docker needs it):

```bash
docker compose up -d                          # start
docker compose down                           # stop
docker compose pull && docker compose up -d   # update to the newest test images
docker compose logs -f                        # logs
```

Re-running the installer in the same folder offers to update, reconfigure
(GPU / ROM path / port, keeping your data) or remove the stack.

## Remove it

```bash
cd romm-streaming
curl -fsSL https://raw.githubusercontent.com/romm-streaming/streaming-tester/main/streaming-tester.sh | bash -s -- remove
```

This stops and deletes the containers and everything the installer created in
that folder. Your ROM library is never touched.

## What's in this repo

- `streaming-tester.sh` — the installer / remover.
- `config.yml` — the RomM config the installer drops into the test stack, with
  streaming enabled for every supported platform.
- `.github/workflows/build-romm.yml` — builds `ghcr.io/romm-streaming/romm` from
  the upstream streaming branch.
