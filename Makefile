PREFIX     := $(CURDIR)
NGINX      := openresty
NGINX_CONF := $(PREFIX)/conf/nginx.conf
REDIS      := redis-server

.DEFAULT_GOAL := help

.PHONY: help check-deps dev stop demo test fmt clean dirs status watch

help:                  ## Show available targets
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*##/ {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

check-deps:            ## Verify openresty + redis are installed
	@bash scripts/check_deps.sh

dirs:                  ## Create runtime directories (logs, run)
	@mkdir -p $(PREFIX)/logs $(PREFIX)/run

dev: check-deps dirs   ## Boot OpenResty in foreground on :8080
	$(NGINX) -p $(PREFIX)/ -c $(NGINX_CONF) -g 'daemon off;'

stop:                  ## Stop a backgrounded OpenResty if any
	$(NGINX) -p $(PREFIX)/ -c $(NGINX_CONF) -s stop || true

demo: check-deps dirs  ## Boot redis + OpenResty for a local demo
	@bash scripts/start_demo.sh

test:                  ## Run busted unit tests
	@command -v busted >/dev/null || { echo "busted not found — luarocks install busted"; exit 1; }
	busted tests/

bench:                 ## Run wrk against /healthz, /metrics, /v1/agents
	@bash scripts/bench.sh

status:                ## Show supervised MCP server status (one-shot table)
	@bash scripts/agent-mux-status.sh

watch:                 ## Live-refreshing MCP server status (Ctrl+C to exit)
	@bash scripts/agent-mux-status.sh --watch

fmt:                   ## Format Lua sources with stylua if available
	@command -v stylua >/dev/null && stylua lua/ tests/ examples/ || echo "stylua not installed — skipping"

clean:                 ## Remove runtime artefacts
	rm -rf $(PREFIX)/logs/* $(PREFIX)/run/*
