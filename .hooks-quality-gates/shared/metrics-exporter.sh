#!/bin/bash
# shared/metrics-exporter.sh
# Export metrics in Prometheus text format for real-time visualization

# Configuration
METRICS_PORT="${METRICS_PORT:-9090}"
METRICS_FILE="${METRICS_FILE:-.teya/execution-metrics.json}"
METRICS_LOG="${METRICS_LOG:-.teya/metrics-export.log}"
METRICS_PID_FILE="${METRICS_PID_FILE:-.teya/metrics-server.pid}"

# Initialize metrics exporter
init_metrics_exporter() {
  mkdir -p "$(dirname "$METRICS_FILE")"
  mkdir -p "$(dirname "$METRICS_LOG")"
  return 0
}

# Format metrics as Prometheus text format
format_prometheus_metrics() {
  local timestamp=$(date +%s000)

  if [ ! -f "$METRICS_FILE" ]; then
    echo "# No metrics available yet"
    return 0
  fi

  cat <<EOF
# HELP hooks_execution_seconds Hook execution time in seconds
# TYPE hooks_execution_seconds gauge
EOF

  # Parse hooks execution times from JSON
  if grep -q "duration_ms" "$METRICS_FILE"; then
    grep -o '"name":"[^"]*".*"duration_ms":[0-9]*' "$METRICS_FILE" 2>/dev/null | sed 's/"name":"\([^"]*\)".*"duration_ms":\([0-9]*\)/hooks_execution_seconds{hook="\1"} \2/' | awk '{print $1, $2/1000}' || true
  fi

  cat <<EOF

# HELP hooks_findings_total Total findings by hook
# TYPE hooks_findings_total gauge
EOF

  # Parse findings counts from JSON
  if grep -q "findings_count" "$METRICS_FILE"; then
    grep -o '"name":"[^"]*".*"findings_count":[0-9]*' "$METRICS_FILE" 2>/dev/null | sed 's/"name":"\([^"]*\)".*"findings_count":\([0-9]*\)/hooks_findings_total{hook="\1"} \2/' || true
  fi

  cat <<EOF

# HELP exceptions_applied_total Total exceptions applied
# TYPE exceptions_applied_total gauge
EOF

  # Parse exception counts from JSON
  if grep -q "total_applied" "$METRICS_FILE"; then
    total_applied=$(grep -o '"total_applied":[0-9]*' "$METRICS_FILE" 2>/dev/null | head -1 | cut -d':' -f2 || echo 0)
    echo "exceptions_applied_total $total_applied $timestamp"
  fi

  cat <<EOF

# HELP gate_evaluator_votes Consensus votes from gate evaluator
# TYPE gate_evaluator_votes gauge
EOF

  # Parse gate votes from JSON
  if grep -q "consensus_votes" "$METRICS_FILE"; then
    votes=$(grep -o '"consensus_votes":[0-9]*' "$METRICS_FILE" 2>/dev/null | head -1 | cut -d':' -f2 || echo 0)
    echo "gate_evaluator_votes $votes $timestamp"
  fi
}

# Export metrics to file in Prometheus format
export_prometheus_format() {
  init_metrics_exporter

  format_prometheus_metrics > "$METRICS_LOG" 2>&1

  log_info "[metrics] Exported metrics to Prometheus format"
  return 0
}

# Start Prometheus HTTP server (if Python available)
start_metrics_server() {
  init_metrics_exporter

  if ! command -v python3 &> /dev/null; then
    log_warn "[metrics] Python3 not available, skipping HTTP server"
    return 1
  fi

  log_info "[metrics] Starting Prometheus exporter on port $METRICS_PORT"

  # Create Python HTTP server script
  local python_script=$(cat <<'PYTHON_EOF'
#!/usr/bin/env python3
import json
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler
from datetime import datetime

class MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/metrics':
            metrics = self.format_prometheus()
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.send_header('Content-Length', len(metrics))
            self.end_headers()
            self.wfile.write(metrics.encode())
        else:
            self.send_response(404)
            self.end_headers()

    def format_prometheus(self):
        try:
            metrics_file = '.teya/execution-metrics.json'
            with open(metrics_file) as f:
                data = json.load(f)

            output = []
            output.append('# HELP hooks_execution_seconds Hook execution time')
            output.append('# TYPE hooks_execution_seconds gauge')

            # Parse per-hook metrics
            if 'execution' in data and 'hooks' in data['execution']:
                for hook in data['execution']['hooks']:
                    name = hook.get('name', 'unknown')
                    duration = hook.get('duration_ms', 0) / 1000
                    output.append(f'hooks_execution_seconds{{hook="{name}"}} {duration}')

            # Add exception metrics
            output.append('# HELP exceptions_applied_total Total exceptions applied')
            output.append('# TYPE exceptions_applied_total gauge')
            if 'exceptions' in data:
                applied = data['exceptions'].get('total_applied', 0)
                output.append(f'exceptions_applied_total {applied}')

            # Add findings metrics
            output.append('# HELP security_findings_total Total findings by tool')
            output.append('# TYPE security_findings_total gauge')
            if 'findings' in data and 'by_tool' in data['findings']:
                for tool, count in data['findings']['by_tool'].items():
                    output.append(f'security_findings_total{{tool="{tool}"}} {count}')

            return '\n'.join(output) + '\n'
        except Exception as e:
            return f'# Error: {str(e)}\n'

    def log_message(self, format, *args):
        pass  # Suppress logging

if __name__ == '__main__':
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9090
    server = HTTPServer(('localhost', port), MetricsHandler)
    print(f'[INFO] Metrics server listening on port {port}', file=sys.stderr)
    server.serve_forever()
PYTHON_EOF
)

  # Start server in background
  echo "$python_script" | python3 /dev/stdin "$METRICS_PORT" > /dev/null 2>&1 &
  local pid=$!

  echo $pid > "$METRICS_PID_FILE"
  log_info "[metrics] Metrics server started (PID: $pid)"

  return 0
}

# Stop metrics HTTP server
stop_metrics_server() {
  if [ -f "$METRICS_PID_FILE" ]; then
    local pid=$(cat "$METRICS_PID_FILE")
    if kill $pid 2>/dev/null; then
      log_info "[metrics] Stopped metrics server (PID: $pid)"
    fi
    rm -f "$METRICS_PID_FILE"
  fi
}

# Check if metrics server is running
is_metrics_server_running() {
  if [ -f "$METRICS_PID_FILE" ]; then
    local pid=$(cat "$METRICS_PID_FILE")
    if ps -p $pid > /dev/null 2>&1; then
      return 0
    fi
  fi
  return 1
}

# Get metrics endpoint URL
get_metrics_url() {
  echo "http://localhost:$METRICS_PORT/metrics"
}

# Export metrics for dashboard (JSON format)
export_for_dashboard() {
  if [ ! -f "$METRICS_FILE" ]; then
    echo "{}"
    return 0
  fi

  cat "$METRICS_FILE"
}

# Validate Prometheus configuration
validate_prometheus_config() {
  local config_file="${1:-prometheus.yml}"

  if [ ! -f "$config_file" ]; then
    return 1
  fi

  # Basic YAML validation
  if ! grep -q "global:" "$config_file"; then
    return 1
  fi

  return 0
}

# Mock logger if not available
if ! command -v log_info &> /dev/null; then
  log_info() { echo "[INFO] $*"; }
  log_warn() { echo "[WARN] $*"; }
  log_error() { echo "[ERROR] $*"; }
  log_debug() { echo "[DEBUG] $*"; }
fi

# Export functions
export METRICS_PORT
export METRICS_FILE
export METRICS_LOG
