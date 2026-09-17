#!/usr/bin/env bash
#
# Boot test build-webstation.yml runs before it tags a new build: the container
# starts without a GPU, the broker answers through nginx the way RomM reaches
# it, and no s6 service restarts while the container sits idle.
#
#   webstation-boot-test.sh IMAGE
#
# IMAGE must already be in the local image store.

set -euo pipefail
shopt -s inherit_errexit

if [ "$#" -ne 1 ]; then
  echo "usage: $0 IMAGE" >&2
  exit 2
fi
image="$1"
name="webstation-boot-test-$$"
secret="$(openssl rand -hex 16)"
status_body="$(mktemp)"
# Ready takes about 4 s on a desktop CPU. A runner that just unpacked 11 GB of
# image gets a lot more headroom.
boot_timeout=180
# How long the container must then stay up with no service restarting.
settle_seconds=30

cleanup() {
  if docker container inspect "$name" >/dev/null 2>&1; then
    docker rm -f -v "$name" >/dev/null
  fi
  rm -f "$status_body"
}
trap cleanup EXIT

# One "svc-NAME UP PID" line per s6 longrun. A restarted service gets a new
# PID, which is harder to miss than counting startup lines in the log.
services() {
  # shellcheck disable=SC2016 # expanded by the container's shell
  docker exec "$name" sh -c 'for s in /run/service/svc-*; do printf "%s " "${s##*/}"; s6-svstat -o up,pid "$s"; done'
}

fail() {
  echo "::error title=webstation boot test::$*"
  echo "::group::webstation boot test diagnostics"
  docker inspect --format 'status={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} started={{.State.StartedAt}}' "$name" || true
  services || true
  docker exec "$name" tail -n 40 /var/log/nginx/error.log || true
  docker logs --tail 300 "$name" 2>&1 | grep -v 'uvicorn.access' || true
  echo "::endgroup::"
  exit 1
}

# Host ports are picked by Docker so nothing else on the machine can collide.
docker run --detach --name "$name" --shm-size 1g \
  --env PUID=1000 --env PGID=1000 --env TZ=Etc/UTC \
  --env BROKER_SECRET="$secret" \
  --publish 127.0.0.1::3000 --publish 127.0.0.1::3001 \
  "$image" >/dev/null
http="http://$(docker port "$name" 3000/tcp | head -n 1)/streaming"
https="https://$(docker port "$name" 3001/tcp | head -n 1)/streaming"

# nginx answers this path with 404 while the broker is down, so only the
# broker's exact body counts as ready. Every service must be up as well, so a
# late starter isn't mistaken for a restart below.
start=$SECONDS
body=""
running=""
until [ "$body" = '{"status":"ok"}' ] && [ -n "$running" ] && ! grep -qv ' true ' <<<"$running"; do
  if (( SECONDS - start >= boot_timeout )); then
    fail "not ready after ${boot_timeout}s (health body: ${body:-none})"
  fi
  if [ "$(docker inspect --format '{{.State.Running}}' "$name")" != true ]; then
    fail "container exited during boot"
  fi
  sleep 2
  body="$(curl -sS --max-time 5 "$http/api/health" 2>/dev/null)" || body=""
  # s6 has no service directory to report on early in boot.
  running="$(services 2>/dev/null)" || running=""
done
echo "ready after $(( SECONDS - start ))s"

# RomM's route: the session router, with and without the broker secret.
code="$(curl -sS -o "$status_body" -w '%{http_code}' --max-time 5 -H "X-Broker-Secret: $secret" "$http/api/session/status")" \
  || fail "session status request with the secret failed"
if [ "$code" != 200 ] || ! grep -q '"active":false' "$status_body"; then
  fail "session status with the secret: HTTP $code $(head -c 200 "$status_body")"
fi
code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$http/api/session/status")" \
  || fail "session status request without the secret failed"
[ "$code" = 403 ] || fail "session status without the secret: expected HTTP 403, got $code"

# The in-browser room is served by the broker, not nginx.
page="$(curl -fsS --max-time 5 "$http/")" || fail "/streaming/ request failed"
grep -qi '<html' <<<"$page" || fail "/streaming/ did not return the room page"

# Same broker over the self-signed HTTPS listener.
body="$(curl -ksS --max-time 5 "$https/api/health")" || fail "HTTPS health request failed"
[ "$body" = '{"status":"ok"}' ] || fail "HTTPS health: ${body:-no body}"

before="$(services)" || fail "could not read s6 service status"
sleep "$settle_seconds"
after="$(services)" || fail "could not read s6 service status after ${settle_seconds}s"
if [ "$before" != "$after" ]; then
  diff <(echo "$before") <(echo "$after") || true
  fail "an s6 service stopped or restarted while idle (diff above)"
fi
body="$(curl -sS --max-time 5 "$http/api/health")" || fail "health request failed after ${settle_seconds}s"
[ "$body" = '{"status":"ok"}' ] || fail "broker stopped answering after ${settle_seconds}s: ${body:-no body}"

logs="$(docker logs "$name" 2>&1)"
if grep -B 2 -A 20 'Traceback (most recent call last)' <<<"$logs"; then
  fail "Python traceback in the container log"
fi

echo "::group::services after ${settle_seconds}s idle"
echo "$after"
echo "::endgroup::"
echo "webstation boot test passed for $image"
