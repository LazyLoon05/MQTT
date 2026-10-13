#!/usr/bin/env bash
set -euo pipefail
# Each task is already isolated. Use /workspace/MQTT; do not create a worktree.
base=/workspace/.mqtt-environment
. /etc/os-release
if [[ "$ID" != debian || "$VERSION_ID" != 13 ]]; then
  echo "This setup expects the provided Debian 13 cloud image." >&2
  exit 1
fi
test -d /workspace/MQTT/.git
test -r /usr/share/keyrings/debian-archive-keyring.gpg
cd /workspace/MQTT
# A refresh replaces broker binaries; stop only the instance managed by this setup.
if [[ -x "$base/stop.sh" ]]; then "$base/stop.sh"; fi
mkdir -p "$base"/{bin,root,run} "$base/apt/etc"/{apt.conf.d,sources.list.d,preferences.d} \
  "$base/apt/state/lists/partial" "$base/apt/cache/archives/partial" "$base/apt/log"
cat > "$base/apt/apt.conf" <<APTCONF
Dir::Etc "$base/apt/etc";
Dir::Etc::sourcelist "sources.list";
Dir::Etc::sourceparts "sources.list.d";
Dir::Etc::main "apt.conf";
Dir::Etc::parts "apt.conf.d";
Dir::State "$base/apt/state";
Dir::State::status "/var/lib/dpkg/status";
Dir::Cache "$base/apt/cache";
Dir::Log "$base/apt/log";
APT::Sandbox::User "$(id -un)";
Acquire::Retries "2";
Acquire::Languages "none";
APTCONF
cat > "$base/apt/etc/sources.list" <<'SOURCES'
deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] https://deb.debian.org/debian trixie main
deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] https://deb.debian.org/debian trixie-updates main
deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] https://deb.debian.org/debian-security trixie-security main
SOURCES
export APT_CONFIG="$base/apt/apt.conf"
/usr/bin/apt-get -o APT::Update::Error-Mode=any update
download_dir=$(mktemp -d "$base/packages.XXXXXX")
trap 'rm -rf "$download_dir"' EXIT
(
  cd "$download_dir"
  /usr/bin/apt-get download mosquitto mosquitto-clients libmosquitto1 libdlt2 libwebsockets19t64
)
for package in "$download_dir"/*.deb; do
  dpkg-deb --extract "$package" "$base/root"
done
lib_dir="$base/root/usr/lib/$(gcc -dumpmachine)"
for tool in mosquitto mosquitto_pub mosquitto_sub; do
  if [[ "$tool" == mosquitto ]]; then tool_path=usr/sbin; else tool_path=usr/bin; fi
  cat > "$base/bin/$tool" <<WRAPPER
#!/usr/bin/env bash
set -euo pipefail
export LD_LIBRARY_PATH="$lib_dir\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "$base/root/$tool_path/$tool" "\$@"
WRAPPER
  chmod +x "$base/bin/$tool"
done
cat > "$base/activate.sh" <<'ACTIVATE'
export PATH="/workspace/.mqtt-environment/bin:$PATH"
ACTIVATE
cat > "$base/broker.conf" <<'BROKER'
listener 1883 127.0.0.1
allow_anonymous true
persistence false
log_dest stdout
BROKER
cat > "$base/start.sh" <<'MQTT_HELPER'
#!/usr/bin/env bash
set -euo pipefail
base=/workspace/.mqtt-environment
pid_file="$base/run/broker.pid"
mkdir -p "$base/run"
if [[ -s "$pid_file" ]]; then
  pid=$(cat "$pid_file")
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    if tr '\0' '\n' < "/proc/$pid/cmdline" | grep -Fxq "$base/broker.conf"; then
      python3 "$base/smoke.py"
      exit 0
    fi
    # A restored PID file can refer to an unrelated process. Do not signal it.
  fi
fi
nohup "$base/bin/mosquitto" -c "$base/broker.conf" > "$base/run/broker.log" 2>&1 < /dev/null &
pid=$!
printf '%s\n' "$pid" > "$pid_file"
for attempt in {1..30}; do
  if ! kill -0 "$pid" 2>/dev/null; then
    cat "$base/run/broker.log" >&2
    rm -f "$pid_file"
    exit 1
  fi
  if python3 -c 'import socket; socket.create_connection(("127.0.0.1",1883),timeout=0.2).close()' 2>/dev/null; then
    python3 "$base/smoke.py"
    kill -0 "$pid"
    echo "Mosquitto running on 127.0.0.1:1883 (PID $pid)"
    exit 0
  fi
  sleep 0.1
done
echo "Broker did not become ready; see $base/run/broker.log" >&2
exit 1
MQTT_HELPER
cat > "$base/stop.sh" <<'MQTT_HELPER'
#!/usr/bin/env bash
set -euo pipefail
base=/workspace/.mqtt-environment
pid_file="$base/run/broker.pid"
if [[ ! -s "$pid_file" ]]; then
  exit 0
fi
pid=$(cat "$pid_file")
if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
  if ! tr '\0' '\n' < "/proc/$pid/cmdline" | grep -Fxq "$base/broker.conf"; then
    echo "PID file belongs to another process; leaving it untouched." >&2
    exit 1
  fi
  kill "$pid"
  for attempt in {1..30}; do
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
fi
rm -f "$pid_file"
MQTT_HELPER
cat > "$base/smoke.py" <<'MQTT_HELPER'
#!/usr/bin/env python3
"""Verify MQTT delivery using the local onboarding tools."""
import pathlib
import subprocess
import uuid

base = pathlib.Path("/workspace/.mqtt-environment")
for version in ("mqttv311", "mqttv5"):
    topic = f"codex/onboarding/{uuid.uuid4().hex}"
    payload = f"{version}-{uuid.uuid4().hex}"
    common = ["-h", "127.0.0.1", "-p", "1883", "-V", version, "-t", topic, "-q", "1"]
    pub = [str(base / "bin/mosquitto_pub"), *common]
    sub = [str(base / "bin/mosquitto_sub"), *common, "-C", "1", "-W", "5"]
    try:
        subprocess.run([*pub, "-r", "-m", payload], check=True, timeout=8, capture_output=True, text=True)
        result = subprocess.run(sub, check=True, timeout=8, capture_output=True, text=True)
        if result.stdout.rstrip("\n") != payload:
            raise RuntimeError(f"Unexpected payload for {version}: {result.stdout!r}")
        print(f"PASS {version}: publish, retained subscribe and exact payload (QoS 1)")
    finally:
        subprocess.run([*pub, "-r", "-n"], check=True, timeout=8, capture_output=True, text=True)
MQTT_HELPER
chmod +x "$base/start.sh" "$base/stop.sh" "$base/smoke.py"
for tool in mosquitto mosquitto_pub mosquitto_sub; do
  status=0
  "$base/bin/$tool" --help > "$base/run/$tool.help" 2>&1 || status=$?
  # These tools deliberately return nonzero for help: broker 3, clients 1.
  if [[ "$tool" == mosquitto ]]; then expected=3; else expected=1; fi
  if [[ "$status" != "$expected" ]]; then
    cat "$base/run/$tool.help" >&2
    echo "$tool help failed with unexpected exit status $status" >&2
    exit 1
  fi
  grep -m 1 'version ' "$base/run/$tool.help"
done
echo "MQTT tools installed in $base/bin; start with $base/start.sh"
