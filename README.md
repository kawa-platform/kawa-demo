# kawa-demo

Mission control on the kawa platform. A spacecraft streams telemetry and state vectors through **kawa gateway** into
Kafka. Each flight controller's console gets exactly the view it needs, and
only the flight director may uplink commands to the crew. Governance keeps the mission's topics in
order, and everything is managed from **kawa studio**.

![Mission control: the spacecraft streams through kawa gateway, which serves filtered virtual topics to the systems and navigator consoles and lets only the flight director uplink commands](docs/mission-control.svg)

The demo shows **SASL clients**, **RBAC**, **filtered virtual topics (JSON and Avro)** and **governance rules**,
with live data. There are two ways to run it, and both tell the same story:

|               | Docker Compose                        | minikube                                              |
|---------------|---------------------------------------|-------------------------------------------------------|
| Start         | `make compose-up`                     | `make k8s-up`                                         |
| Studio        | http://localhost:5173/admin/          | `make k8s-forward`, then http://localhost:5173/admin/ |
| Kafka clients | `localhost:9092`, or `make consume …` | `make k8s-consume …` (inside the cluster)             |
| Stop          | `make compose-down`                   | `make k8s-down`                                       |

Studio login: `admin@kawa` / `admin`. For another password, set `KAWA_ADMIN_PASSWORD`, e.g.
`KAWA_ADMIN_PASSWORD=s3cret make compose-up`. The gateway creates the admin user with it on its
first start only, so on an existing stack run `make compose-down` first.

## Prerequisites

- Docker with Compose v2, plus `make`, `curl` and `jq`.
- For minikube: `minikube`, `kubectl`, `helm` and `envsubst` (`brew install gettext`). The chart is
  installed from a `../kawa-charts` checkout next to this repo.

## Resources
### Topics

**Physical topics.** An init job creates them on the broker:

- `telemetry.raw`: JSON readings, one per second, for two crafts (`artemis-3`, `gateway`) and four
  subsystems (power, thermal, life-support, propulsion). Most readings are `nominal`, the rest
  `caution`, `warning` or `critical`.
- `navigation.raw`: Avro state vectors ([`schemas/state-vector.avsc`](schemas/state-vector.avsc)).
- `commands.uplink`: commands to the crew.

**Virtual topics.** Each is a server-side CEL filter:

- `telemetry.alerts` over `telemetry.raw` keeps `value.severity in ["warning", "critical"]`.
- `navigation.artemis` over `navigation.raw` keeps `value.craft == "artemis-3"`. The gateway
  decodes the Avro values with the schema registry before filtering them.
 
### Clients

**SASL clients.** The password is `<name>-secret`, and each client's consumer groups are
`<name>.*`.

| Client       | Who                     | May                                                              |
|--------------|-------------------------|------------------------------------------------------------------|
| `spacecraft` | the flight computer     | write `telemetry.raw` and `navigation.raw`; receive `commands.uplink` |
| `director`   | the flight director     | read everything, uplink to `commands.*`, create topics           |
| `systems`    | the systems engineer    | read `telemetry.alerts` only                                     |
| `navigator`  | the navigation officer  | read `navigation.artemis` only                                   |

**Seeding.** [`scripts/seed.sh`](scripts/seed.sh) loads all of this through the admin API. It logs
in headlessly with [`scripts/token.sh`](scripts/token.sh), which performs the OAuth
authorization-code + PKCE flow without a browser.

## The client commands

The Kafka client targets run Kafka's own CLI in a container, as one of the SASL clients. Every
parameter has a default, and you can set any of them on the command line:

| Target | What it does | Parameters (default) |
|---|---|---|
| `make consume` | consume a topic through the gateway, as a client | `CLIENT` (`systems`), `TOPIC` (`telemetry.alerts`), `GROUP` (`<client>.console`), `MAX` (no limit; with `MAX`, also stop after `MAX_WAIT` seconds, `30`) |
| `make send` | produce one command through the gateway, as a client | `CLIENT` (`director`), `TOPIC` (`commands.uplink`) |
| `make kafka-consume` | consume from the broker directly, with no gateway, filters or RBAC | `TOPIC` (`telemetry.raw`), `MAX` |
| `make topic` | create a topic through the gateway, so governance applies | `NAME`, `PARTITIONS` (`3`), `CONFIGS` (`key=value,...`), `CLIENT` (`director`) |
| `make commands` | follow the spacecraft, which receives what's uplinked to `commands.uplink` | |
| `make avro` | produce Avro state vectors as `spacecraft`, then read `navigation.artemis` as `navigator` | |

For example, the navigator trying to read the systems engineer's topic gets nothing, because RBAC
hides `telemetry.alerts` from it. After 30 seconds it stops with *"navigator cannot see
telemetry.alerts"*:

```bash
make consume CLIENT=navigator TOPIC=telemetry.alerts MAX=1
```

On minikube the same targets have a `k8s-` prefix and take the same parameters.

## Walkthrough (Compose)

```bash
make compose-up
```

1. **Studio.** Open http://localhost:5173/admin/ and sign in. Under topics, RBAC and clients you'll
   find what the seed created.
2. **The alerts console.** The systems engineer consumes `telemetry.alerts` and sees only the
   warnings and criticals, not the nominal readings:
   ```bash
   make consume CLIENT=systems TOPIC=telemetry.alerts
   ```
   To check that nominal and caution readings are produced too, read the physical topic
   `telemetry.raw` from the broker itself, bypassing the gateway:
   ```bash
   make kafka-consume TOPIC=telemetry.raw
   ```
3. **Commands and RBAC.** Only the flight director talks to the spacecraft. The director uplinks a
   burn command to `commands.uplink`:
   ```bash
   make send CLIENT=director TOPIC=commands.uplink
   ```
   The spacecraft consumes `commands.uplink` and prints each command it receives:
   ```bash
   make commands
   ```
   When the systems engineer tries the same, the gateway hides `commands.uplink` from it, and the
   produce times out with *"not present in metadata"*:
   ```bash
   make send CLIENT=systems TOPIC=commands.uplink
   ```
   A consumer group outside the client's own `systems.*` is refused with
   `GroupAuthorizationException`:
   ```bash
   make consume CLIENT=systems TOPIC=telemetry.alerts GROUP=other
   ```
4. **Avro.** The spacecraft produces eight Avro state vectors to `navigation.raw`. Then the
   navigator consumes `navigation.artemis` and gets only the four for artemis-3, printed decoded:
   ```bash
   make avro
   ```
5. **Governance.** `make compose-up` loads these rules right after the seed:
    - topic names are `<domain>.<name>`, with domain one of telemetry, navigation, commands, comms
      or payload;
    - partition counts must be 1, 3, 6 or 12;
    - command topics keep at least 7 days of data for the post-flight review;
    - consumer groups are `<client>.<purpose>`.

   After editing [`scripts/governance.sh`](scripts/governance.sh), reload them with:
   ```bash
   make governance
   ```
   Try them, creating topics as the director. `comms.loop-a` is created:
   ```bash
   make topic CLIENT=director NAME=comms.loop-a
   ```
   These three are rejected with `PolicyViolationException`, one per rule:
   ```bash
   make topic CLIENT=director NAME=Houston
   ```
   ```bash
   make topic CLIENT=director NAME=payload.big PARTITIONS=5
   ```
   ```bash
   make topic CLIENT=director NAME=commands.abort CONFIGS=retention.ms=60000
   ```
   A consumer group named against the rule gets `InvalidGroupIdException`:
   ```bash
   make consume CLIENT=systems TOPIC=telemetry.alerts GROUP=systems.Bad_Name
   ```
   The rules also show up in Studio under governance.
6. **The admin API directly:**
   ```bash
   export KAWA_TOKEN=$(make -s token)
   ```
   ```bash
   curl -s -H "Authorization: Bearer $KAWA_TOKEN" localhost:8080/topics | jq
   ```

Kafka clients on your machine can connect to `localhost:9092` with one of the configs in
[`clients/`](clients). The broker itself is on `localhost:19092` and the schema registry on
`localhost:8081`, for inspection.

## Walkthrough (minikube)

```bash
make k8s-up
```

`make k8s-up` does the following:

1. Starts minikube if needed, in a profile of its own (`kawa-demo`; set `MINIKUBE_PROFILE` to
   change it). It uses the kubectl context of the same name, so your other clusters stay untouched.
   Resources: `MINIKUBE_CPUS` (default 4) and `MINIKUBE_MEMORY` (default 4g).
2. Loads the kawa images into minikube.
3. Applies Kafka and the schema registry ([`k8s/`](k8s)) in the namespace `kawa-demo`.
4. Installs the kawa chart with [`k8s/values-minikube.yaml`](k8s/values-minikube.yaml) and the
   versions from `versions.env`.
5. Runs the seed job, then starts the spacecraft and the tool pods.

Re-run it to roll out new versions.

To open Studio, start the port-forwards and keep them running in their own terminal:

```bash
make k8s-forward
```

Studio is then at http://localhost:5173/admin/. The admin API is forwarded to `localhost:8080`,
because the studio rc image calls it there from the browser.

The walkthrough steps match the Compose ones, with a `k8s-` prefix and the same parameters:

```bash
make k8s-consume CLIENT=systems TOPIC=telemetry.alerts
```

```bash
make k8s-kafka-consume TOPIC=telemetry.raw
```

```bash
make k8s-send CLIENT=director TOPIC=commands.uplink
```

```bash
make k8s-commands
```

```bash
make k8s-send CLIENT=systems TOPIC=commands.uplink
```

```bash
make k8s-avro
```

```bash
make k8s-governance
```

```bash
make k8s-topic CLIENT=director NAME=Houston
```

To see each pod and the image it runs:

```bash
make k8s-ps
```

`make k8s-down` removes the release and the namespace. To delete the cluster too, run:

```bash
minikube delete -p kawa-demo
```

## Layout

| Path                        | What                                                                                                                                  |
|-----------------------------|---------------------------------------------------------------------------------------------------------------------------------------|
| `versions.env`              | Image and version of every component                                                                                                  |
| `Makefile`                  | Every entry point (`make help`)                                                                                                       |
| `config/gateway.yaml`       | Startup config of the Compose gateway (minikube: the chart renders it)                                                                |
| `compose/`                  | `docker-compose.yml`                                                                                                                  |
| `k8s/`                      | Kafka, schema registry and demo workloads; chart values; up/down/forward scripts                                                      |
| `scripts/`                  | `token.sh` (headless admin login), `seed.sh`, `governance.sh`, the telemetry and state vector producers, and the Kafka client scripts |
| `clients/`                  | SASL client configs for spacecraft, director, systems and navigator                                                                            |
| `schemas/state-vector.avsc` | Avro schema of the state vectors                                                                                                      |

## Versions

Every component is pinned in [`versions.env`](versions.env):

```
GATEWAY_IMAGE=ghcr.io/kawa-platform/kawa-gateway
GATEWAY_VERSION=0.1.0-rc.2
STUDIO_IMAGE=ghcr.io/kawa-platform/kawa-studio
STUDIO_VERSION=0.1.0-rc.1
KAFKA_VERSION=4.3.1
SCHEMA_REGISTRY_VERSION=8.0.0
KAWA_CHART=../kawa-charts/charts/kawa
```

To pin a version for good, edit the file. To override one for a single run, set it on the command
line or in the shell; those values win over the file:

```bash
make compose-up GATEWAY_VERSION=0.1.0-rc.3
```

```bash
STUDIO_VERSION=edge make k8s-up
```

Image tags have no leading `v`: git tag `v0.1.0-rc.2` is image `0.1.0-rc.2`. `make versions` shows
the effective versions and checks that every tag exists, for amd64 and arm64.

To run unreleased code, set a component's version to `local`. `make compose-up` and `make k8s-up`
then build that component's image from its source checkout first, as `<image>:local`. The checkouts
are `GATEWAY_SRC` and `STUDIO_SRC` in `versions.env`, relative to this directory; they default to
`../kawa-gateway` and `../kawa-studio`. You can mix local and released components, for example a
local gateway with the released studio:

```bash
make compose-up GATEWAY_VERSION=local
```

To build without starting anything, use `make build-gateway`, `make build-studio` or
`make build-local` (both).

