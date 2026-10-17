# kawa-demo: mission control on the kawa platform, on Docker Compose or minikube. `make help` lists the targets.
#
# Component versions live in versions.env. Override any of them for one run:
#   make compose-up GATEWAY_VERSION=0.1.0-rc.3
#   STUDIO_VERSION=edge make k8s-up

SHELL := /bin/bash
.DEFAULT_GOAL := help

# Load versions.env without overriding values from the environment or the make command line.
VERSION_VARS := $(shell sed -n 's/^\([A-Z_][A-Z0-9_]*\)=.*/\1/p' versions.env)
$(foreach v,$(VERSION_VARS),$(eval $(v) ?= $(shell sed -n 's/^$(v)=//p' versions.env)))
export $(VERSION_VARS)

COMPOSE := docker compose -f compose/docker-compose.yml --env-file versions.env

CLIENT ?= systems
TOPIC ?= telemetry.alerts

SEND_CLIENT = $(if $(filter command line environment,$(origin CLIENT)),$(CLIENT),director)
KAFKA_TOPIC = $(if $(filter command line environment,$(origin TOPIC)),$(TOPIC),telemetry.raw)
KAFKA_CONSUME = /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server kafka:9092 --topic $(KAFKA_TOPIC) \
	--from-beginning --property print.timestamp=true $(if $(MAX),--max-messages $(MAX) --timeout-ms 15000)
SEND_TOPIC = $(if $(filter command line environment,$(origin TOPIC)),$(TOPIC),commands.uplink)

MAX ?=
GROUP ?=
MAX_WAIT ?= 30
NAME ?=
PARTITIONS ?= 3
CONFIGS ?=

KAWA_IMAGES = $(GATEWAY_IMAGE):$(GATEWAY_VERSION) $(STUDIO_IMAGE):$(STUDIO_VERSION)
# Components whose version is `local`: built from *_SRC before compose-up / k8s-up.
LOCAL_BUILDS = $(if $(filter local,$(GATEWAY_VERSION)),build-gateway) $(if $(filter local,$(STUDIO_VERSION)),build-studio)

ALL_IMAGES = $(KAWA_IMAGES) $(KAFKA_IMAGE):$(KAFKA_VERSION) $(KAFKA_TOOLS_IMAGE):$(KAFKA_VERSION) \
	$(SCHEMA_REGISTRY_IMAGE):$(SCHEMA_REGISTRY_VERSION)

.PHONY: help
help: ## List the targets
	@awk 'BEGIN {FS = ":.*## "} /^[a-z0-9-]+:.*## / {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2} /^## / {printf "\n%s\n", substr($$0, 4)}' $(MAKEFILE_LIST)

## Versions
.PHONY: versions
versions: ## Show the effective component versions and check every image tag exists
	@for v in $(VERSION_VARS); do printf '  %-24s %s\n' "$$v" "$${!v}"; done
	@echo
	@ok=1; for img in $(ALL_IMAGES); do \
		if [[ "$$img" == *:local ]]; then printf '  \033[33mlocal\033[0m %-58s built from source\n' "$$img"; continue; fi; \
		archs=$$(docker manifest inspect "$$img" 2>/dev/null | jq -r '[.manifests[]?.platform | select(.os == "linux") | .architecture] | unique | join(",")' 2>/dev/null); \
		if docker manifest inspect "$$img" >/dev/null 2>&1; then printf '  \033[32mok\033[0m   %-58s %s\n' "$$img" "$${archs:-single-arch}"; \
		else printf '  \033[31mmissing\033[0m %s\n' "$$img"; ok=0; fi; \
	done; [ $$ok = 1 ] || { echo; echo "Some tags do not exist (kawa image tags have no leading v: 0.1.0-rc.2)."; exit 1; }

.PHONY: pull
pull: ## Pull every image of the demo
	@for img in $(ALL_IMAGES); do [[ "$$img" == *:local ]] || docker pull -q "$$img"; done

.PHONY: build-gateway build-studio build-local
build-gateway: ## Build the gateway image from GATEWAY_SRC, tagged :local
	docker build -t $(GATEWAY_IMAGE):local $(GATEWAY_SRC)

build-studio: ## Build the studio image from STUDIO_SRC, tagged :local
	docker build -t $(STUDIO_IMAGE):local $(STUDIO_SRC)

build-local: build-gateway build-studio ## Build both; versions set to `local` are built by compose-up / k8s-up anyway

## Docker Compose
.PHONY: compose-up
compose-up: $(LOCAL_BUILDS) ## Start mission control on compose (Kafka, schema registry, gateway, studio, gateway-init, spacecraft)
	$(COMPOSE) up -d --remove-orphans
	@[ "$$($(COMPOSE) ps -a gateway-init --format '{{.ExitCode}}')" = 0 ] || { $(COMPOSE) logs gateway-init; echo "💥 gateway-init failed"; exit 1; }
	@echo
	@$(COMPOSE) ps --format '{{.Service}} {{.Image}}' gateway studio | \
		awk '{ split($$2, ref, ":"); printf "  %-13s %s   (%s)\n", "kawa " $$1, ref[length(ref)], $$2 }'
	@echo
	@echo "  🖥️  kawa studio   http://localhost:5173/admin/   (admin@kawa / $${KAWA_ADMIN_PASSWORD:-admin})"
	@echo "  📡 gateway      localhost:9092 (SASL PLAIN: spacecraft, director, systems, navigator / <name>-secret)"
	@echo "  🔧 admin API     http://localhost:8080          (token: make token)"
	@echo
	@echo "  👉 next: make consume   (systems watches telemetry alerts)   |   make help"

.PHONY: compose-down
compose-down: ## Stop the compose demo and delete its data
	$(COMPOSE) --profile tools down -v --remove-orphans

.PHONY: compose-ps
compose-ps: ## Show the compose demo's containers and their images
	$(COMPOSE) ps -a --format 'table {{.Service}}\t{{.Image}}\t{{.Status}}'

.PHONY: compose-logs
compose-logs: ## Follow the gateway's logs
	$(COMPOSE) logs -f gateway

.PHONY: token
token: ## Print an admin API access token (export KAWA_TOKEN=$(make -s token))
	@ADMIN_URL=$${ADMIN_URL:-http://localhost:8080} scripts/token.sh

.PHONY: gateway-init
gateway-init: ## Re-run the mission control gateway setup (virtual topics, clients, RBAC)
	$(COMPOSE) run --rm admin /demo/scripts/gateway-init.sh

.PHONY: governance
governance: ## Reload the governance rules (compose-up loads them already), e.g. after editing governance.sh
	$(COMPOSE) run --rm admin /demo/scripts/governance.sh

.PHONY: commands
commands: ## Follow the commands the spacecraft receives (what make send uplinks)
	$(COMPOSE) logs -f --no-log-prefix spacecraft

.PHONY: consume
consume: ## Consume TOPIC (default telemetry.alerts) as CLIENT (default systems); MAX=n to stop after n
	@$(COMPOSE) run --rm -e CLIENT=$(CLIENT) -e TOPIC=$(TOPIC) -e MAX=$(MAX) -e MAX_WAIT=$(MAX_WAIT) -e GROUP=$(GROUP) tools /bin/sh /demo/scripts/consume.sh

.PHONY: kafka-consume
kafka-consume: ## Consume TOPIC (default telemetry.raw) from the broker directly, bypassing the gateway
	@echo "consuming $(KAFKA_TOPIC) from the broker directly (no gateway: no filters, no RBAC)" >&2
	@$(COMPOSE) run --rm tools $(KAFKA_CONSUME)

.PHONY: send
send: ## Uplink a command to TOPIC (default commands.uplink) as CLIENT (default director); try CLIENT=systems
	@$(COMPOSE) run --rm -e CLIENT=$(SEND_CLIENT) -e TOPIC=$(SEND_TOPIC) tools /bin/sh /demo/scripts/send.sh

.PHONY: topics
topics: ## List the topics the gateway advertises to CLIENT (default director)
	@$(COMPOSE) run --rm -e CLIENT=$(SEND_CLIENT) tools /bin/sh /demo/scripts/list-topics.sh

.PHONY: topic
topic: ## Create topic NAME (PARTITIONS=3, CONFIGS=k=v,...) as director, so governance applies
	@$(COMPOSE) run --rm -e CLIENT=$(SEND_CLIENT) -e NAME=$(NAME) -e PARTITIONS=$(PARTITIONS) -e CONFIGS=$(CONFIGS) tools /bin/sh /demo/scripts/create-topic.sh

.PHONY: avro
avro: ## Produce Avro state vectors to navigation.raw, then read navigation.artemis as navigator
	@$(COMPOSE) run --rm avro /demo/scripts/produce-state-vectors.sh
	@$(COMPOSE) run --rm avro /demo/scripts/consume-avro.sh

## Minikube
.PHONY: k8s-up
k8s-up: $(LOCAL_BUILDS) ## Start mission control on minikube (Kafka, schema registry, kawa chart, gateway-init, telemetry)
	k8s/up.sh

.PHONY: k8s-forward
k8s-forward: ## Port-forward studio (5173) and the admin API (8080) from minikube
	k8s/forward.sh

KC = kubectl --context $${MINIKUBE_PROFILE:-kawa-demo} -n kawa-demo
KC_EXEC = $(KC) exec $$([ -t 0 ] && echo -it || echo -i)

.PHONY: k8s-ps
k8s-ps: ## Show the minikube demo's pods and their images
	$(KC) get pods -o custom-columns='POD:.metadata.name,IMAGE:.spec.containers[0].image,STATUS:.status.phase'

.PHONY: k8s-token
k8s-token: ## Print an admin API access token for the minikube gateway
	@k8s/admin.sh token.sh

.PHONY: k8s-gateway-init
k8s-gateway-init: ## Re-run the mission control gateway setup on minikube
	k8s/admin.sh gateway-init.sh

.PHONY: k8s-governance
k8s-governance: ## Reload the governance rules on minikube
	k8s/admin.sh governance.sh

.PHONY: k8s-commands
k8s-commands: ## Follow the commands the spacecraft receives, on minikube
	$(KC) logs -f deploy/kawa-spacecraft

.PHONY: k8s-consume
k8s-consume: ## Consume TOPIC as CLIENT on minikube (like make consume)
	@$(KC_EXEC) deploy/kawa-tools -- env CLIENT=$(CLIENT) TOPIC=$(TOPIC) MAX=$(MAX) MAX_WAIT=$(MAX_WAIT) GROUP=$(GROUP) /bin/sh /demo/scripts/consume.sh

.PHONY: k8s-kafka-consume
k8s-kafka-consume: ## Consume TOPIC (default telemetry.raw) from the broker directly on minikube
	@echo "consuming $(KAFKA_TOPIC) from the broker directly (no gateway: no filters, no RBAC)" >&2
	@$(KC_EXEC) deploy/kawa-tools -- $(KAFKA_CONSUME)

.PHONY: k8s-send
k8s-send: ## Uplink a command (like make send) on minikube
	@$(KC_EXEC) deploy/kawa-tools -- env CLIENT=$(SEND_CLIENT) TOPIC=$(SEND_TOPIC) /bin/sh /demo/scripts/send.sh

.PHONY: k8s-topic
k8s-topic: ## Create topic NAME through the gateway on minikube, so governance applies
	@$(KC_EXEC) deploy/kawa-tools -- env CLIENT=$(SEND_CLIENT) NAME=$(NAME) PARTITIONS=$(PARTITIONS) CONFIGS=$(CONFIGS) /bin/sh /demo/scripts/create-topic.sh

.PHONY: k8s-avro
k8s-avro: ## Produce Avro state vectors, then read navigation.artemis as navigator, on minikube
	@$(KC) exec deploy/kawa-avro-tools -- /demo/scripts/produce-state-vectors.sh
	@$(KC) exec deploy/kawa-avro-tools -- /demo/scripts/consume-avro.sh

.PHONY: k8s-down
k8s-down: ## Remove the demo from minikube
	k8s/down.sh
